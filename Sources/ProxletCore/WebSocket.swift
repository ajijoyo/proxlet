//
//  WebSocket.swift
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

/// One WebSocket message as stored in `websockets/<flow-id>.jsonl`.
public struct WebSocketMessage: Codable, Hashable, Sendable {
    public init(time: Date, direction: String, type: String, size: Int, text: String) {
        self.time = time
        self.direction = direction
        self.type = type
        self.size = size
        self.text = text
    }

    public var time: Date
    /// "send" (client → server) or "receive" (server → client).
    public var direction: String
    /// "text", "binary", "close", "ping" or "pong".
    public var type: String
    public var size: Int
    /// UTF-8 payload (capped), or a placeholder for binary frames.
    public var text: String
}

public enum WebSocketStore {
    /// Per-connection cap; the relay keeps working, only recording stops.
    static let maxMessages = 10_000
    static let lock = NSLock()

    static func file(_ flowID: String) -> URL {
        Paths.root.appendingPathComponent("websockets", isDirectory: true).appendingPathComponent("\(flowID).jsonl")
    }

    public static func append(_ message: WebSocketMessage, flowID: String) {
        lock.lock()
        defer { lock.unlock() }
        let url = file(flowID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let line = try? FlowStore.encoder.encode(message) else { return }
        try? FlowStore.appendLine(line, to: url)
    }

    /// Messages of one WebSocket flow, oldest first.
    public static func load(flowID: String) -> [WebSocketMessage] {
        guard let data = try? Data(contentsOf: file(flowID)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? FlowStore.decoder.decode(WebSocketMessage.self, from: Data($0)) }
    }

    public static func delete(flowIDs: Set<String>) {
        for id in flowIDs { try? FileManager.default.removeItem(at: file(id)) }
    }
}

/// Parses RFC 6455 frames from a copy of the relayed bytes; never alters the traffic.
final class FrameParser {
    /// Frames (or reassembled messages) above this are not recorded; parsing stops for that direction.
    static let maxFrame = 16_000_000
    private var buffer = [UInt8]()
    private var fragments = [UInt8]()
    private var fragmentType = "text"
    private var gaveUp = false

    private struct Frame {
        let size: Int
        let fin: Bool
        let opcode: UInt8
        let payload: [UInt8]
    }

    /// Feeds bytes and returns completed messages as (type, payload).
    func feed(_ bytes: [UInt8]) -> [(String, [UInt8])] {
        guard !gaveUp else { return [] }
        buffer += bytes
        var out: [(String, [UInt8])] = []
        while let frame = nextFrame() {
            buffer.removeFirst(frame.size)
            if let message = message(from: frame) { out.append(message) }
            if fragments.count > Self.maxFrame {
                giveUp()
                return out
            }
        }
        return out
    }

    /// Completed message for a frame, reassembling continuation frames.
    private func message(from frame: Frame) -> (String, [UInt8])? {
        switch frame.opcode {
        case 0x0:
            fragments += frame.payload
            guard frame.fin else { return nil }
            defer { fragments = [] }
            return (fragmentType, fragments)
        case 0x1, 0x2:
            let type = frame.opcode == 0x1 ? "text" : "binary"
            if frame.fin { return (type, frame.payload) }
            fragmentType = type
            fragments = frame.payload
            return nil
        case 0x8: return ("close", frame.payload)
        case 0x9: return ("ping", frame.payload)
        case 0xA: return ("pong", frame.payload)
        default: return nil
        }
    }

    /// Payload length and where the mask/payload starts, or nil when more header bytes are needed.
    private func payloadLength() -> (length: Int, offset: Int)? {
        let short = Int(buffer[1] & 0x7F)
        switch short {
        case 126:
            guard buffer.count >= 4 else { return nil }
            return (Int(buffer[2]) << 8 | Int(buffer[3]), 4)
        case 127:
            guard buffer.count >= 10 else { return nil }
            return (buffer[2..<10].reduce(0) { $0 << 8 | Int($1) }, 10)
        default:
            return (short, 2)
        }
    }

    private func nextFrame() -> Frame? {
        guard buffer.count >= 2, let (length, headerEnd) = payloadLength() else { return nil }
        // Hostile or huge lengths: stop parsing instead of overflowing `offset + length` or buffering forever.
        guard length >= 0, length <= Self.maxFrame else {
            giveUp()
            return nil
        }
        let masked = buffer[1] & 0x80 != 0
        let offset = headerEnd + (masked ? 4 : 0)
        guard buffer.count >= offset, length <= buffer.count - offset else { return nil }
        var payload = Array(buffer[offset..<offset + length])
        if masked {
            let mask = Array(buffer[headerEnd..<offset])
            for i in payload.indices { payload[i] ^= mask[i % 4] }
        }
        return Frame(size: offset + length, fin: buffer[0] & 0x80 != 0, opcode: buffer[0] & 0x0F, payload: payload)
    }

    private func giveUp() {
        gaveUp = true
        buffer = []
        fragments = []
    }
}

/// Records the handshake as a flow and both directions' messages; lives on one event loop.
final class WebSocketRecorder {
    private let request: ProxyRequest
    private let store: FlowStore
    private let started = Date()
    private var responseHead = [UInt8]()
    private var flowID: String?
    private var upgraded = false
    private let sendParser = FrameParser()
    private let receiveParser = FrameParser()
    private var recorded = 0
    static let maxText = 1_000_000

    init(request: ProxyRequest, store: FlowStore) {
        self.request = request
        self.store = store
    }

    func clientBytes(_ bytes: [UInt8]) {
        guard upgraded else { return }
        record(sendParser.feed(bytes), direction: "send")
    }

    func serverBytes(_ bytes: [UInt8]) {
        if upgraded {
            record(receiveParser.feed(bytes), direction: "receive")
            return
        }
        guard flowID == nil else { return }
        responseHead += bytes
        guard let end = responseHead.firstRange(of: [13, 10, 13, 10])?.lowerBound else { return }
        let headText = String(decoding: responseHead[..<end], as: UTF8.self)
        let rest = Array(responseHead[(end + 4)...])
        var lines = headText.components(separatedBy: "\r\n")
        let status = Int(lines.removeFirst().split(separator: " ").dropFirst().first ?? "") ?? 0
        let headers = lines.compactMap { line -> Header? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return Header(name: String(line[..<colon]), value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let flow = Flow(request: request, response: ProxyResponse(status: status, headers: headers, body: Data()),
                        startedAt: started, mocked: false, error: nil, websocket: status == 101)
        flowID = flow.id
        store.append(flow)
        upgraded = status == 101
        if upgraded, !rest.isEmpty { record(receiveParser.feed(rest), direction: "receive") }
    }

    private func record(_ messages: [(String, [UInt8])], direction: String) {
        guard let id = flowID, store.isRecording else { return }
        for (type, payload) in messages where recorded < WebSocketStore.maxMessages {
            recorded += 1
            let text: String
            switch type {
            case "binary": text = "<binary \(payload.count) bytes>"
            case "close":
                let code = payload.count >= 2 ? Int(payload[0]) << 8 | Int(payload[1]) : 0
                text = payload.count >= 2 ? "\(code) \(String(decoding: payload.dropFirst(2), as: UTF8.self))" : ""
            default: text = String(decoding: payload.prefix(Self.maxText), as: UTF8.self)
            }
            WebSocketStore.append(WebSocketMessage(time: Date(), direction: direction, type: type, size: payload.count, text: text),
                                  flowID: id)
        }
    }
}

/// Copies bytes to the peer channel and tees them to the recorder.
final class RawRelay: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    var peer: Channel? {
        didSet {
            guard let peer, !pending.isEmpty else { return }
            for buf in pending { peer.write(buf, promise: nil) }
            peer.flush()
            pending.removeAll()
        }
    }
    private var pending: [ByteBuffer] = []
    private let tee: ([UInt8]) -> Void

    init(peer: Channel?, tee: @escaping ([UInt8]) -> Void) {
        self.peer = peer
        self.tee = tee
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        tee(Array(buf.readableBytesView))
        // No backpressure: fine for debugging traffic, not for bulk transfers.
        if let peer { peer.writeAndFlush(buf, promise: nil) } else { pending.append(buf) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

enum WebSocketProxy {

    /// Raw HTTP/1.1 handshake to send upstream; drops proxy-only headers and compression so frames stay readable.
    static func handshake(_ head: HTTPRequestHead, path: String, host: String) -> String {
        var headers = head.headers
        for name in ["Proxy-Connection", "Proxy-Authorization", "Sec-WebSocket-Extensions"] { headers.remove(name: name) }
        if !headers.contains(name: "Host") { headers.add(name: "Host", value: host) }
        return "GET \(path) HTTP/1.1\r\n" + headers.map { "\($0.name): \($0.value)\r\n" }.joined() + "\r\n"
    }

    /// Where and how to reach the WebSocket server.
    struct Upstream {
        let host: String
        let port: Int
        /// nil for ws://
        let tls: NIOSSLContext?
        let handshake: String
    }

    /// Opens the upstream socket, sends the handshake and wires the two relays together.
    static func connect(_ upstream: Upstream, on loop: EventLoop, client: Channel, clientRelay: RawRelay, recorder: WebSocketRecorder) {
        let (host, port, tls, handshake) = (upstream.host, upstream.port, upstream.tls, upstream.handshake)
        // SNI must be a host name; IP literals are sent without it.
        let sni = host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) ? nil : host
        ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        try channel.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: tls, serverHostname: sni))
                    }
                    try channel.pipeline.syncOperations.addHandler(RawRelay(peer: client) { recorder.serverBytes($0) })
                }
            }
            .connect(host: host, port: port)
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    // The client may have gone away while we were connecting.
                    guard client.isActive else {
                        channel.close(promise: nil)
                        return
                    }
                    channel.writeAndFlush(ByteBuffer(string: handshake), promise: nil)
                    clientRelay.peer = channel
                case .failure(let error):
                    NSLog("Proxlet: WebSocket upstream \(host):\(port) failed: \(error)")
                    let body = "Proxlet WebSocket upstream error: \(error)\n"
                    let reply = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    client.writeAndFlush(ByteBuffer(string: reply)).whenComplete { _ in client.close(promise: nil) }
                }
            }
    }

    static func isUpgrade(_ head: HTTPRequestHead) -> Bool {
        head.headers["upgrade"].contains { $0.lowercased().contains("websocket") }
    }
}
