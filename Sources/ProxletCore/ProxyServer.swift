//
//  ProxyServer.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// HTTP/1.1 proxy. Plain requests are forwarded; CONNECT is answered with 200 and the
/// connection is re-terminated as TLS using a leaf cert for the target host (MITM).
public final class ProxyServer: @unchecked Sendable {
    public let port: Int
    let ca: CertificateAuthority
    let pipeline: FlowPipeline
    let access: AccessControl?
    private var channel: Channel?

    /// `access` nil lets every client in.
    public init(port: Int, ca: CertificateAuthority, pipeline: FlowPipeline, access: AccessControl? = nil) {
        self.port = port
        self.ca = ca
        self.pipeline = pipeline
        self.access = access
    }

    public func start() async throws {
        let port = self.port
        let ca = self.ca
        let pipeline = self.pipeline
        let access = self.access
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let install = {
                    ProxyHandler.install(on: channel.pipeline, ca: ca, flows: pipeline, tunnel: nil,
                                         client: ClientApp(channel: channel, proxyPort: port))
                }
                guard let access, let ip = channel.remoteAddress?.ipAddress else { return install() }
                // The connection isn't read until this decides, so a pending prompt holds it open.
                let decision = channel.eventLoop.makePromise(of: Bool.self)
                decision.completeWithTask { await access.isAllowed(ip) }
                return decision.futureResult.flatMap { $0 ? install() : channel.close() }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "0.0.0.0", port: port)
            .get()
    }

    public func stop() async {
        try? await channel?.close()
        channel = nil
    }

    /// Actual listening port (useful when started on port 0).
    public var boundPort: Int? { channel?.localAddress?.port }

    /// `host:port`, `[v6]:port` or bare host from a CONNECT target; port defaults to 443.
    static func authority(_ target: String) -> (host: String, port: Int) {
        if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
            let host = String(target[target.index(after: target.startIndex)..<close])
            let rest = target[target.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? 443 : 443)
        }
        guard let colon = target.lastIndex(of: ":") else { return (target, 443) }
        return (String(target[..<colon]), Int(target[target.index(after: colon)...]) ?? 443)
    }
}

/// Looks up the client behind a connection once, in the background; shared with its CONNECT tunnel.
/// Local apps resolve via libproc; a network client (phone) is identified by its IP.
final class ClientApp: Sendable {
    let task: Task<ProcessLookup.Client?, Never>?

    init(channel: Channel, proxyPort: Int) {
        guard let remote = channel.remoteAddress, let ip = remote.ipAddress, let port = remote.port else {
            task = nil
            return
        }
        guard AccessControl.isLocal(ip) else {
            task = Task { ProcessLookup.Client(app: nil, device: ip) }
            return
        }
        task = Task.detached(priority: .utility) { ProcessLookup.client(clientPort: port, proxyPort: proxyPort) }
    }
}

/// Origin of a decrypted CONNECT tunnel, used to rebuild absolute URLs.
struct TunnelTarget {
    let host: String
    let port: Int
}

final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let ca: CertificateAuthority
    let flows: FlowPipeline
    let tunnel: TunnelTarget?
    let client: ClientApp
    let encoder: HTTPResponseEncoder
    let decoder: ByteToMessageHandler<HTTPRequestDecoder>

    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    private init(ca: CertificateAuthority, flows: FlowPipeline, tunnel: TunnelTarget?, client: ClientApp,
                 encoder: HTTPResponseEncoder, decoder: ByteToMessageHandler<HTTPRequestDecoder>) {
        self.ca = ca
        self.flows = flows
        self.tunnel = tunnel
        self.client = client
        self.encoder = encoder
        self.decoder = decoder
    }

    static func install(on pipeline: ChannelPipeline, ca: CertificateAuthority, flows: FlowPipeline,
                        tunnel: TunnelTarget?, client: ClientApp) -> EventLoopFuture<Void> {
        let encoder = HTTPResponseEncoder()
        let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
        let handler = ProxyHandler(ca: ca, flows: flows, tunnel: tunnel, client: client, encoder: encoder, decoder: decoder)
        return pipeline.eventLoop.makeCompletedFuture {
            try pipeline.syncOperations.addHandlers([encoder, decoder, handler])
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let h = head else { return }
            head = nil
            if h.method == .CONNECT {
                startTunnel(context: context, head: h)
            } else if WebSocketProxy.isUpgrade(h) {
                startWebSocket(context: context, head: h)
            } else {
                forward(context: context, head: h, body: Data(buffer: body))
            }
        }
    }

    private func startTunnel(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let (host, port) = ProxyServer.authority(head.uri)
        guard SSLProxying.load().shouldDecrypt(host) else { return passThrough(context: context, head: head, host: host, port: port) }
        let sslContext: NIOSSLContext
        do {
            sslContext = try ca.serverContext(for: host)
        } catch {
            NSLog("Proxlet: cert for \(host) failed: \(error)")
            context.close(promise: nil)
            return
        }
        let resHead = HTTPResponseHead(version: head.version, status: .init(statusCode: 200, reasonPhrase: "Connection Established"),
                                       headers: ["Content-Length": "0"])
        context.write(wrapOutboundOut(.head(resHead)), promise: nil)
        let pipeline = context.pipeline
        let channel = context.channel
        let ca = self.ca
        let flows = self.flows
        let client = self.client
        let encoder = self.encoder
        let decoder = self.decoder
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            do {
                // Swap plain HTTP handlers for TLS + a fresh HTTP stack bound to this host.
                let ops = pipeline.syncOperations
                ops.removeHandler(self, promise: nil)
                ops.removeHandler(encoder, promise: nil)
                try ops.addHandler(NIOSSLServerHandler(context: sslContext))
                ops.removeHandler(decoder, promise: nil)
                _ = ProxyHandler.install(on: pipeline, ca: ca, flows: flows, tunnel: TunnelTarget(host: host, port: port), client: client)
            } catch {
                NSLog("Proxlet: tunnel setup for \(host) failed: \(error)")
                channel.close(promise: nil)
            }
        }
    }

    /// CONNECT to a host outside the SSL Proxying list: relay the encrypted bytes untouched and record only the tunnel.
    private func passThrough(context: ChannelHandlerContext, head: HTTPRequestHead, host: String, port: Int) {
        let started = Date()
        let client = context.channel
        let (flows, app, encoder, decoder) = (self.flows, self.client, self.encoder, self.decoder)
        let upstreamRelay = RawRelay(peer: nil) { _ in }
        let request = ProxyRequest(method: "CONNECT", url: "https://" + (host.contains(":") ? "[\(host)]" : host) + (port == 443 ? "" : ":\(port)"),
                                   headers: head.headers.map { Header(name: $0.name, value: $0.value) }, body: Data())
        func record(_ status: Int, _ error: String?) {
            Task {
                var req = request
                let client = await app.task?.value
                req.clientApp = client?.app
                req.clientDevice = client?.device
                flows.store.append(Flow(request: req, response: ProxyResponse(status: status, headers: [], body: Data()),
                                        startedAt: started, mocked: false, error: error))
            }
        }
        ClientBootstrap(group: context.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(upstreamRelay) }
            }
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case .success(let upstream):
                    guard client.isActive else { return upstream.close(promise: nil) }
                    let ok = HTTPResponseHead(version: head.version, status: .init(statusCode: 200, reasonPhrase: "Connection Established"),
                                              headers: ["Content-Length": "0"])
                    context.write(self.wrapOutboundOut(.head(ok)), promise: nil)
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
                        do {
                            // Same swap as WebSocket: bytes the decoder still holds flow into the relay.
                            let ops = context.pipeline.syncOperations
                            try ops.addHandler(RawRelay(peer: upstream) { _ in })
                            ops.removeHandler(self, promise: nil)
                            ops.removeHandler(encoder, promise: nil)
                            ops.removeHandler(decoder, promise: nil)
                            upstreamRelay.peer = client
                            record(200, nil)
                        } catch {
                            upstream.close(promise: nil)
                            client.close(promise: nil)
                        }
                    }
                case .failure(let error):
                    let fail = HTTPResponseHead(version: head.version, status: .badGateway, headers: ["Content-Length": "0", "Connection": "close"])
                    context.write(self.wrapOutboundOut(.head(fail)), promise: nil)
                    context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in client.close(promise: nil) }
                    record(502, "Tunnel to \(host):\(port) failed: \(error)")
                }
            }
    }

    /// Read-only WebSocket proxying: forward the handshake, then relay raw bytes both ways while recording frames.
    private func startWebSocket(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let url = absoluteURL(head)
        guard let c = URLComponents(string: url), let host = c.host else {
            context.close(promise: nil)
            return
        }
        let secure = c.scheme == "https" || c.scheme == "wss"
        let port = c.port ?? (secure ? 443 : 80)
        let path = (c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath) + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
        let handshake = WebSocketProxy.handshake(head, path: path, host: host)
        let wsURL = (secure ? "wss" : "ws") + url.drop { $0 != ":" }
        let request = ProxyRequest(method: head.method.rawValue, url: wsURL,
                                   headers: head.headers.map { Header(name: $0.name, value: $0.value) }, body: Data())
        let recorder = WebSocketRecorder(request: request, store: flows.store)
        let clientRelay = RawRelay(peer: nil) { recorder.clientBytes($0) }
        let clientChannel = context.channel
        do {
            // Swap HTTP parsing for a raw relay; any bytes the decoder still holds flow into the relay.
            let ops = context.pipeline.syncOperations
            try ops.addHandler(clientRelay)
            ops.removeHandler(self, promise: nil)
            ops.removeHandler(encoder, promise: nil)
            ops.removeHandler(decoder, promise: nil)
        } catch {
            context.close(promise: nil)
            return
        }
        let upstream = WebSocketProxy.Upstream(host: host, port: port, tls: secure ? flows.webSocketTLS : nil, handshake: handshake)
        WebSocketProxy.connect(upstream, on: context.eventLoop, client: clientChannel, clientRelay: clientRelay, recorder: recorder)
    }

    private func absoluteURL(_ head: HTTPRequestHead) -> String {
        guard let t = tunnel else { return head.uri }
        let portPart = t.port == 443 ? "" : ":\(t.port)"
        let host = t.host.contains(":") ? "[\(t.host)]" : t.host
        return "https://\(host)\(portPart)\(head.uri)"
    }

    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        let req = ProxyRequest(
            method: head.method.rawValue,
            url: absoluteURL(head),
            headers: head.headers.map { Header(name: $0.name, value: $0.value) },
            body: body
        )
        let keepAlive = head.isKeepAlive
        let version = head.version
        let isHead = head.method == .HEAD
        let promise = context.eventLoop.makePromise(of: ProxyResponse.self)
        let flows = self.flows
        let client = self.client
        promise.completeWithTask {
            var withApp = req
            let found = await client.task?.value
            withApp.clientApp = found?.app
            withApp.clientDevice = found?.device
            return await flows.handle(withApp)
        }
        promise.futureResult.whenSuccess { res in
            var headers = HTTPHeaders(res.headers.map { ($0.name, $0.value) })
            switch res.status {
            case 100..<200, 204: headers.remove(name: "Content-Length")  // must not carry a length
            case _ where (isHead || res.status == 304) && res.body.isEmpty && headers.contains(name: "Content-Length"):
                break  // keep the upstream length of the resource
            default: headers.replaceOrAdd(name: "Content-Length", value: "\(res.body.count)")
            }
            headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
            let resHead = HTTPResponseHead(version: version, status: .init(statusCode: res.status), headers: headers)
            context.write(self.wrapOutboundOut(.head(resHead)), promise: nil)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: res.body)))), promise: nil)
            let done = context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
            if !keepAlive { done.whenComplete { _ in context.close(promise: nil) } }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        NSLog("Proxlet: connection error (\(tunnel?.host ?? "plain")): \(error)")
        context.close(promise: nil)
    }
}
