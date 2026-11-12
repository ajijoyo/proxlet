//
//  TestSupport.swift
//  ProxletCoreTests
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
@testable import ProxletCore
import XCTest

/// Every test gets its own data directory, so nothing touches ~/Library/Application Support/Proxlet.
class ProxletTestCase: XCTestCase {
    override func setUpWithError() throws {
        Paths.root = FileManager.default.temporaryDirectory.appendingPathComponent("proxlet-test-\(UUID().uuidString)")
        try Paths.ensure()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: Paths.root)
    }

    /// Polls until `condition` holds; for work that finishes on another task (recording, detached writes).
    func eventually(_ what: String, timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        let held = condition()
        XCTAssertTrue(held, what)
    }

    func writeScript(_ name: String, _ source: String) throws {
        try source.write(to: Paths.scripts.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func flow(_ url: String, method: String = "GET", requestHeaders: [Header] = [], responseBody: Data = Data()) -> Flow {
        Flow(request: ProxyRequest(method: method, url: url, headers: requestHeaders, body: Data()),
             response: ProxyResponse(status: 200, headers: [], body: responseBody), startedAt: Date(), mocked: false, error: nil)
    }

    /// TLS trust for upstreams whose certs are signed by this test's CA.
    func trusting(_ ca: CertificateAuthority) throws -> TLSConfiguration {
        var tls = TLSConfiguration.makeClientConfiguration()
        let pem = try ca.certificate.serializeAsPEM().pemString
        tls.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem)])
        return tls
    }
}

/// Local upstream server. Paths: `/echo` (request as JSON), `/gzip-ok`, `/gzip-bad`, `/resource` (HEAD: length only),
/// `/nocontent` (204), `/image` (1×1 PNG), `/cached` (ETag, Last-Modified, max-age); anything else returns `ok`.
final class TestUpstream {
    let channel: Channel
    var port: Int { channel.localAddress!.port! }

    private init(channel: Channel) { self.channel = channel }

    static func start(tls: NIOSSLContext? = nil) async throws -> TestUpstream {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls { try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(UpstreamHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return TestUpstream(channel: channel)
    }

    func stop() async { try? await channel.close() }

    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
}

private final class UpstreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?

    // swiftlint:disable:next large_tuple
    static func respond(to head: HTTPRequestHead) -> (HTTPResponseStatus, HTTPHeaders, Data) {
        var headers: HTTPHeaders = ["Content-Type": "application/json"]
        var status = HTTPResponseStatus.ok
        var body = Data("ok".utf8)
        switch head.uri.split(separator: "?").first.map(String.init) ?? "" {
        case "/echo":
            let echoed = Dictionary(head.headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { a, b in "\(a), \(b)" })
            body = (try? JSONSerialization.data(withJSONObject: ["method": head.method.rawValue, "headers": echoed])) ?? Data()
        case "/gzip-ok":
            body = ContentDecoding.gzip(Data(#"{"zipped":true}"#.utf8)) ?? Data()
            headers.add(name: "Content-Encoding", value: "gzip")
        case "/gzip-bad":
            body = Data("definitely not gzip".utf8)
            headers.add(name: "Content-Encoding", value: "gzip")
        case "/cached":
            headers.add(name: "ETag", value: "\"v1\"")
            headers.add(name: "Last-Modified", value: "Wed, 11 Nov 2026 00:00:00 GMT")
            headers.add(name: "Cache-Control", value: "max-age=3600")
        case "/image":
            body = TestUpstream.png
            headers.replaceOrAdd(name: "Content-Type", value: "image/png")
        case "/nocontent":
            status = .noContent
            body = Data()
        default: break
        }
        if head.uri == "/resource", head.method == .HEAD {
            headers.add(name: "Content-Length", value: "12345")
            body = Data()
        } else if status != .noContent {
            headers.add(name: "Content-Length", value: "\(body.count)")
        }
        return (status, headers, body)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h): head = h
        case .body: break
        case .end:
            guard let head else { return }
            let (status, headers, body) = Self.respond(to: head)
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
            if !body.isEmpty { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil) }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

/// WebSocket echo server: replies `echo:<text>` to every text frame.
final class TestWebSocketServer {
    let channel: Channel
    var port: Int { channel.localAddress!.port! }

    private init(channel: Channel) { self.channel = channel }

    static func start() async throws -> TestWebSocketServer {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture([:]) },
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoFrames()) }
                    })
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return TestWebSocketServer(channel: channel)
    }

    func stop() async { try? await channel.close() }
}

private final class EchoFrames: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var payload = frame.unmaskedData
            let text = payload.readString(length: payload.readableBytes) ?? ""
            let reply = ByteBuffer(string: "echo:" + text)
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .text, data: reply)), promise: nil)
        case .connectionClose:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.data)))
                .whenComplete { _ in context.close(promise: nil) }
        default:
            break
        }
    }
}

/// Minimal blocking TCP client for raw protocol tests (WebSocket through the proxy).
final class RawSocket {
    private let fd: Int32

    init(port: Int, host: String = "127.0.0.1") throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: in_port_t(UInt16(port).bigEndian), sin_addr: in_addr(s_addr: inet_addr(host)),
                               sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { throw POSIXError(.ECONNREFUSED) }
    }

    deinit { close(fd) }

    func send(_ bytes: [UInt8]) { _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, bytes.count, 0) } }

    /// Reads until `count` bytes arrived or the 5 s timeout hits.
    func receive(atLeast count: Int) -> [UInt8] {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while out.count < count {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            out += chunk.prefix(n)
        }
        return out
    }

    /// Reads up to and including the blank line that ends an HTTP head; returns the head and any extra bytes.
    func receiveHead() -> (head: String, rest: [UInt8]) {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while out.firstRange(of: [13, 10, 13, 10]) == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            out += chunk.prefix(n)
        }
        guard let end = out.firstRange(of: [13, 10, 13, 10]) else { return (String(decoding: out, as: UTF8.self), []) }
        return (String(decoding: out[..<end.lowerBound], as: UTF8.self), Array(out[end.upperBound...]))
    }
}

/// Client WebSocket frame (masked, as RFC 6455 requires).
func maskedFrame(opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let mask: [UInt8] = [7, 1, 3, 9]
    return [0x80 | opcode, 0x80 | UInt8(payload.count)] + mask + payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
}
