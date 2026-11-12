//
//  FlowPipeline.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// Map Local → script onRequest → upstream → script onResponse → record.
public final class FlowPipeline: @unchecked Sendable {
    public let store: FlowStore
    let scripts = ScriptEngine()
    let client: HTTPClient

    /// Master switches; individual rules/scripts still apply only when these are on.
    public var mapLocalEnabled: Bool {
        get { lock.withLock { mapLocal } }
        set { lock.withLock { mapLocal = newValue } }
    }
    public var scriptsEnabled: Bool {
        get { lock.withLock { scriptsOn } }
        set { lock.withLock { scriptsOn = newValue } }
    }
    /// No Caching for traffic that isn't mocked or scripted.
    public var noCachingEnabled: Bool {
        get { lock.withLock { noCaching } }
        set { lock.withLock { noCaching = newValue } }
    }
    private var mapLocal = true
    private var scriptsOn = true
    private var noCaching = false
    private let lock = NSLock()

    static let hopByHop: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "proxy-authorization", "proxy-authenticate",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length", "host",
    ]
    static let maxUpstreamBody = 100_000_000
    static let conditionalHeaders: Set<String> = ["if-none-match", "if-modified-since"]
    static let cacheHeaders: Set<String> = ["cache-control", "expires", "etag", "last-modified", "age", "pragma"]

    /// Replaces caching headers with `no-store` so the client never reuses this response.
    public static func noStore(_ headers: [Header]) -> [Header] {
        headers.filter { !cacheHeaders.contains($0.name.lowercased()) } + [Header(name: "Cache-Control", value: "no-store")]
    }

    /// TLS context for wss:// upstreams (same trust as `client`).
    let webSocketTLS: NIOSSLContext?

    /// `upstreamTLS` overrides certificate trust for upstream servers (tests use a local CA); nil means system trust.
    public init(store: FlowStore, upstreamTLS: TLSConfiguration? = nil) {
        self.store = store
        let tls = upstreamTLS ?? .makeClientConfiguration()
        webSocketTLS = try? NIOSSLContext(configuration: tls)
        var config = HTTPClient.Configuration()
        config.tlsConfiguration = tls
        // Decoded by ContentDecoding so a malformed stream is passed through instead of failing.
        config.decompression = .disabled
        config.redirectConfiguration = .disallow
        config.timeout = .init(connect: .seconds(15), read: .seconds(60))
        // POSIX sockets, not Network.framework: the latter honors the system proxy and would loop back into Proxlet.
        client = HTTPClient(eventLoopGroup: MultiThreadedEventLoopGroup.singleton, configuration: config)
    }

    public func handle(_ original: ProxyRequest) async -> ProxyResponse {
        let started = Date()
        if let local = LocalPages.response(for: original) { return local }
        if mapLocalEnabled, let rule = RuleStore.match(method: original.method, url: original.url) {
            if let delay = rule.delayMs, delay > 0 {
                try? await Task.sleep(for: .milliseconds(min(delay, MockRule.maxDelayMs)))
            }
            // onResponse scripts still run on top of a Map Local response.
            var res = rule.response()
            var applied: [String] = []
            var error: String?
            if scriptsEnabled {
                let result = scripts.onResponse(original, res)
                res = result.value
                applied = result.applied
                if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
            }
            store.append(Flow(request: original, response: res, startedAt: started, mocked: true, error: error, scripts: applied),
                         responseBody: res.body)
            return res
        }
        // When a script applies, skip the browser cache both ways so toggling scripts takes effect on the next request.
        let useScripts = scriptsEnabled && scripts.hasMatch(method: original.method, url: original.url)
        var outgoing = original
        // Scripted traffic is always fresh, so toggling a script shows on the next request; No Caching does it for the rest.
        let fresh = useScripts || noCachingEnabled
        if fresh { outgoing.headers.removeAll { Self.conditionalHeaders.contains($0.name.lowercased()) } }
        let requestRun = useScripts ? scripts.onRequest(outgoing) : .init(value: outgoing, errors: [], applied: [])
        let req = requestRun.value
        var res: ProxyResponse
        var error: String?
        do {
            res = try await forward(req)
        } catch let e {
            error = "\(e)"
            res = ProxyResponse(status: 502, headers: [Header(name: "Content-Type", value: "text/plain")],
                                body: Data("Proxlet upstream error: \(e)\n".utf8))
        }
        let responseRun = useScripts ? scripts.onResponse(req, res) : .init(value: res, errors: [], applied: [])
        var finalRes = responseRun.value
        if fresh { finalRes.headers = Self.noStore(finalRes.headers) }
        let errors = requestRun.errors + responseRun.errors
        if !errors.isEmpty { error = ([error].compactMap { $0 } + errors).joined(separator: "\n") }
        let applied = (requestRun.applied + responseRun.applied).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        store.append(Flow(request: req, response: finalRes, startedAt: started, mocked: false, error: error, scripts: applied),
                     responseBody: finalRes.body)
        return finalRes
    }

    // Response is buffered whole; stream it if large downloads matter.
    func forward(_ req: ProxyRequest) async throws -> ProxyResponse {
        var out = HTTPClientRequest(url: req.url)
        out.method = HTTPMethod(rawValue: req.method)
        for h in req.headers where !Self.hopByHop.contains(h.name.lowercased()) && h.name.lowercased() != "accept-encoding" {
            out.headers.add(name: h.name, value: h.value)
        }
        out.headers.add(name: "Accept-Encoding", value: ContentDecoding.acceptEncoding)
        if !req.body.isEmpty { out.body = .bytes(ByteBuffer(bytes: req.body)) }
        let res = try await client.execute(out, timeout: .seconds(60))
        var body = Data(buffer: try await res.body.collect(upTo: Self.maxUpstreamBody))
        // HEAD and 304 have no body but their Content-Length describes the resource, so keep it.
        let keepLength = body.isEmpty && (req.method.uppercased() == "HEAD" || res.status.code == 304)
        var headers = res.headers
            .filter { !Self.hopByHop.contains($0.name.lowercased()) || (keepLength && $0.name.lowercased() == "content-length") }
            .map { Header(name: $0.name, value: $0.value) }
        if let encoding = res.headers.first(name: "content-encoding"),
           let decoded = ContentDecoding.decode(body, encoding: encoding) {
            body = decoded
            headers.removeAll { $0.name.lowercased() == "content-encoding" }
        }
        return ProxyResponse(status: Int(res.status.code), headers: headers, body: body)
    }

    private var isShutDown = false

    public func shutdown() async {
        isShutDown = true
        try? await client.shutdown()
    }

    // AsyncHTTPClient traps if a client is deallocated while running (e.g. a test that fails before shutdown()).
    // The last reference can drop on an event loop, where syncShutdown() traps too, so shut down without waiting.
    deinit {
        if !isShutDown { client.shutdown { _ in } }
    }
}
