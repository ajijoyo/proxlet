//
//  PipelineTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import NIOCore
import NIOHTTP1
@testable import ProxletCore
import X509
import XCTest

final class PipelineTests: ProxletTestCase {
    func get(_ pipeline: FlowPipeline, _ url: String, method: String = "GET", headers: [Header] = []) async -> ProxyResponse {
        await pipeline.handle(ProxyRequest(method: method, url: url, headers: headers, body: Data()))
    }

    func json(_ res: ProxyResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
    }

    func testGlobalSwitchesApplyToNextRequest() async throws {
        let upstream = try await TestUpstream.start()
        let base = "http://127.0.0.1:\(upstream.port)"
        try RuleStore.save(MockRule(id: "m", urlPattern: "\(base)/mock*", status: 299, body: "mock"))
        try writeScript("s.js", "// @match \(base)/echo*\nfunction onResponse(req, res) { res.status = 288; return res; }")
        let pipeline = FlowPipeline(store: FlowStore())

        let mocked = await get(pipeline, "\(base)/mock")
        XCTAssertEqual(mocked.status, 299)
        XCTAssertTrue(mocked.headers.contains(Header(name: "Cache-Control", value: "no-store")))
        let scripted = await get(pipeline, "\(base)/echo", headers: [Header(name: "If-None-Match", value: "x")])
        XCTAssertEqual(scripted.status, 288)
        XCTAssertTrue(scripted.headers.contains(Header(name: "Cache-Control", value: "no-store")))
        let echoed = try XCTUnwrap(json(scripted)["headers"] as? [String: String])
        XCTAssertNil(echoed["if-none-match"], "conditional headers are dropped so the server can't answer 304")

        pipeline.mapLocalEnabled = false
        pipeline.scriptsEnabled = false
        let real = await get(pipeline, "\(base)/mock")
        XCTAssertEqual(String(decoding: real.body, as: UTF8.self), "ok")
        let unscripted = await get(pipeline, "\(base)/echo")
        XCTAssertEqual(unscripted.status, 200)
        await pipeline.shutdown()
        await upstream.stop()
    }

    func testMapLocalPerSimulatorAndDeviceFilter() async throws {
        let sim = "61376D3D-F1AF-45F2-90D5-8AE58DF2B60C"
        try RuleStore.save(MockRule(id: "general", urlPattern: "https://api.example.com/v*", status: 200))
        try RuleStore.save(MockRule(id: "sim", urlPattern: "https://api.example.com/v*", status: 426, devices: [sim]))
        let pipeline = FlowPipeline(store: FlowStore())
        let simRes = await pipeline.handle(ProxyRequest(method: "GET", url: "https://api.example.com/v1", headers: [], body: Data(),
                                                        clientDevice: sim))
        let otherRes = await get(pipeline, "https://api.example.com/v1")
        XCTAssertEqual([simRes.status, otherRes.status], [426, 200])
        let flows = FlowStore.load()
        XCTAssertEqual(flows.map(\.device), [sim, nil])
        XCTAssertEqual(flows.filter { FlowQuery.matches($0, .init(key: "device", matching: "equal", value: sim)) }.count, 1)
        await pipeline.shutdown()
    }

    func testScriptRunsOnTopOfMapLocal() async throws {
        try RuleStore.save(MockRule(id: "enc", urlPattern: "https://api.example.com/meta*", body: #"{"data":"cipher"}"#))
        try writeScript("decrypt.js", """
        // @match https://api.example.com/*
        // @request false
        function onResponse(req, res) { var j = JSON.parse(res.body); j._decrypted = "plain"; res.body = JSON.stringify(j); return res; }
        """)
        let pipeline = FlowPipeline(store: FlowStore())
        let res = await get(pipeline, "https://api.example.com/meta/1")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: String]),
                       ["data": "cipher", "_decrypted": "plain"])
        let flow = try XCTUnwrap(FlowStore.load().last)
        XCTAssertTrue(flow.mocked)
        XCTAssertEqual(flow.scripts, ["decrypt.js"])

        pipeline.scriptsEnabled = false
        let plain = await get(pipeline, "https://api.example.com/meta/1")
        XCTAssertEqual(String(decoding: plain.body, as: UTF8.self), #"{"data":"cipher"}"#)
        XCTAssertEqual(FlowStore.load().last?.scripts, [])
        await pipeline.shutdown()
    }

    func testImageBodiesAreKeptBesideTheFlow() async throws {
        let upstream = try await TestUpstream.start()
        let base = "http://127.0.0.1:\(upstream.port)"
        let store = FlowStore()
        let pipeline = FlowPipeline(store: store)
        _ = await get(pipeline, "\(base)/image")
        _ = await get(pipeline, "\(base)/echo")
        store.isRecording = false
        _ = await get(pipeline, "\(base)/image?paused")

        let flows = FlowStore.load()
        XCTAssertEqual(flows.count, 2, "nothing is recorded while paused")
        let image = try XCTUnwrap(flows.first { $0.url.hasSuffix("/image") })
        XCTAssertTrue(image.hasPartialResponseBody, "flows.jsonl still holds only the placeholder")
        XCTAssertEqual(BodyStore.load(flowID: image.id), TestUpstream.png)
        XCTAssertNil(BodyStore.load(flowID: try XCTUnwrap(flows.first { $0.url.hasSuffix("/echo") }).id), "only images are kept")
        let bodies = try FileManager.default.contentsOfDirectory(atPath: Paths.root.appendingPathComponent("bodies").path)
        XCTAssertEqual(bodies, [image.id])

        BodyStore.delete(flowIDs: [image.id])
        XCTAssertNil(BodyStore.load(flowID: image.id))
        await upstream.stop()
    }

    func testForwardFiltersHeadersAndDecodesOrPassesThrough() async throws {
        let upstream = try await TestUpstream.start()
        let base = "http://127.0.0.1:\(upstream.port)"
        let pipeline = FlowPipeline(store: FlowStore())

        let echo = await get(pipeline, "\(base)/echo", headers: [
            Header(name: "Proxy-Connection", value: "keep-alive"), Header(name: "Accept-Encoding", value: "zstd"),
            Header(name: "X-Keep", value: "1"),
        ])
        let sent = try XCTUnwrap(json(echo)["headers"] as? [String: String])
        XCTAssertNil(sent["proxy-connection"])
        XCTAssertEqual(sent["accept-encoding"], ContentDecoding.acceptEncoding)
        XCTAssertEqual(sent["x-keep"], "1")

        let good = await get(pipeline, "\(base)/gzip-ok")
        XCTAssertEqual(String(decoding: good.body, as: UTF8.self), #"{"zipped":true}"#)
        XCTAssertFalse(good.headers.contains { $0.name.lowercased() == "content-encoding" })

        let bad = await get(pipeline, "\(base)/gzip-bad")
        XCTAssertEqual(String(decoding: bad.body, as: UTF8.self), "definitely not gzip", "undecodable bodies pass through")
        XCTAssertTrue(bad.headers.contains(Header(name: "Content-Encoding", value: "gzip")))

        let head = await get(pipeline, "\(base)/resource", method: "HEAD")
        XCTAssertTrue(head.headers.contains(Header(name: "Content-Length", value: "12345")), "HEAD keeps the resource length")
        await pipeline.shutdown()
        await upstream.stop()
    }

    func testLocalCertificatePages() throws {
        let missing = LocalPages.response(for: ProxyRequest(method: "GET", url: "/ssl", headers: [], body: Data()))
        XCTAssertEqual(missing?.status, 404)

        _ = try CertificateAuthority.loadOrCreate()
        let pem = try XCTUnwrap(LocalPages.response(for: ProxyRequest(method: "GET", url: "/ssl", headers: [], body: Data())))
        XCTAssertEqual(pem.status, 200)
        XCTAssertTrue(pem.headers.contains(Header(name: "Content-Type", value: "application/x-x509-ca-cert")))
        XCTAssertTrue(String(decoding: pem.body, as: UTF8.self).hasPrefix("-----BEGIN CERTIFICATE-----"))
        let crt = LocalPages.response(for: ProxyRequest(method: "GET", url: "/ssl.crt", headers: [], body: Data()))
        XCTAssertEqual(crt?.headers.first { $0.name == "Content-Disposition" }?.value, #"attachment; filename="Proxlet-CA.crt""#)
        let viaProxy = LocalPages.response(for: ProxyRequest(method: "GET", url: "http://proxlet.ssl/", headers: [], body: Data()))
        XCTAssertEqual(viaProxy?.status, 200)
        XCTAssertNil(LocalPages.response(for: ProxyRequest(method: "GET", url: "https://example.com/ssl", headers: [], body: Data())))
    }

    func testConnectAuthorityParsing() {
        XCTAssertEqual(ProxyServer.authority("api.example.com:8443").host, "api.example.com")
        XCTAssertEqual(ProxyServer.authority("api.example.com:8443").port, 8443)
        XCTAssertEqual(ProxyServer.authority("api.example.com").port, 443)
        XCTAssertEqual(ProxyServer.authority("[::1]:8443").host, "::1")
        XCTAssertEqual(ProxyServer.authority("[::1]:8443").port, 8443)
        XCTAssertEqual(ProxyServer.authority("[fe80::1]").port, 443)
    }

    func testLeafForIPLiteralUsesIPAddressSAN() throws {
        let ca = try CertificateAuthority.loadOrCreate()
        let ip = try XCTUnwrap(ca.leafCertificate(for: "127.0.0.1").extensions.subjectAlternativeNames)
        XCTAssertTrue(ip.contains { if case .ipAddress = $0 { true } else { false } })
        let v6 = try XCTUnwrap(ca.leafCertificate(for: "::1").extensions.subjectAlternativeNames)
        XCTAssertTrue(v6.contains { if case .ipAddress = $0 { true } else { false } })
        let dns = try XCTUnwrap(ca.leafCertificate(for: "api.example.com").extensions.subjectAlternativeNames)
        XCTAssertEqual(Array(dns), [.dnsName("api.example.com")])
    }

    /// Runs curl through the proxy (a stock client, so CONNECT/TLS behave like a real app); returns status, headers, body.
    private struct CurlResult {
        let status: Int
        let headers: [String: String]
        let body: String
    }

    private func curl(proxy: Int, _ extra: [String]) throws -> CurlResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-i", "--max-time", "10", "-x", "http://127.0.0.1:\(proxy)", "--cacert", Paths.caCert.path] + extra
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        // With -i over a CONNECT tunnel curl prints the proxy's 200 first; the last head is the origin's.
        let heads = out.components(separatedBy: "\r\n\r\n")
        let lastHead = heads.dropLast().last { $0.hasPrefix("HTTP/") } ?? ""
        var lines = lastHead.components(separatedBy: "\r\n")
        let status = Int(lines.removeFirst().split(separator: " ").dropFirst().first ?? "") ?? 0
        var headers: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1] }
        }
        return CurlResult(status: status, headers: headers, body: heads.last ?? "")
    }

    /// Full path: client → CONNECT → raw tunnel, or MITM TLS with a Proxlet leaf (IP SAN) once the host is in the
    /// SSL Proxying list → HTTPS upstream; plus HEAD/204 length rules.
    func testProxyServerMITMAndContentLength() async throws {
        let ca = try CertificateAuthority.loadOrCreate()
        let upstream = try await TestUpstream.start(tls: try ca.serverContext(for: "127.0.0.1"))
        let plain = try await TestUpstream.start()
        let pipeline = FlowPipeline(store: FlowStore(), upstreamTLS: try trusting(ca))
        let proxy = ProxyServer(port: 0, ca: ca, pipeline: pipeline)
        try await proxy.start()
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        // Empty list (the default): the TLS session is the upstream's own, only the tunnel is recorded.
        let passed = try curl(proxy: proxyPort, ["https://127.0.0.1:\(upstream.port)/hello"])
        XCTAssertEqual(passed.status, 200)
        XCTAssertEqual(passed.body, "ok")
        await eventually("tunnel recorded") { FlowStore.load().last?.method == "CONNECT" }
        let tunnel = try XCTUnwrap(FlowStore.load().last)
        XCTAssertEqual(tunnel.method, "CONNECT")
        XCTAssertEqual(tunnel.url, "https://127.0.0.1:\(upstream.port)")

        try SSLProxying.update { $0.add("127.0.0.1") }
        let decrypted = try curl(proxy: proxyPort, ["https://127.0.0.1:\(upstream.port)/hello"])
        XCTAssertEqual(decrypted.status, 200)
        XCTAssertEqual(decrypted.body, "ok")
        await eventually("decrypted request recorded") { FlowStore.load().last?.url == "https://127.0.0.1:\(upstream.port)/hello" }

        let head = try curl(proxy: proxyPort, ["-I", "http://127.0.0.1:\(plain.port)/resource"])
        XCTAssertEqual(head.headers["content-length"], "12345")
        let noContent = try curl(proxy: proxyPort, ["http://127.0.0.1:\(plain.port)/nocontent"])
        XCTAssertEqual(noContent.status, 204)
        XCTAssertNil(noContent.headers["content-length"])

        await proxy.stop()
        await pipeline.shutdown()
        await upstream.stop()
        await plain.stop()
    }

    func testWebSocketRelayRecordsBothDirections() async throws {
        let echo = try await TestWebSocketServer.start()
        let ca = try CertificateAuthority.loadOrCreate()
        let pipeline = FlowPipeline(store: FlowStore())
        let proxy = ProxyServer(port: 0, ca: ca, pipeline: pipeline)
        try await proxy.start()
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        let socket = try RawSocket(port: proxyPort)
        socket.send(Array("""
        GET http://127.0.0.1:\(echo.port)/chat HTTP/1.1\r
        Host: 127.0.0.1:\(echo.port)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        Sec-WebSocket-Extensions: permessage-deflate\r
        \r

        """.utf8))
        let (head, rest) = socket.receiveHead()
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 101"), head)
        XCTAssertFalse(head.lowercased().contains("permessage-deflate"), "compression is not negotiated")
        socket.send(maskedFrame(opcode: 0x1, Array("hello".utf8)))
        let reply = rest + socket.receive(atLeast: max(0, 2 + 10 - rest.count))
        XCTAssertEqual(String(decoding: reply.dropFirst(2), as: UTF8.self), "echo:hello")
        socket.send(maskedFrame(opcode: 0x8, [0x03, 0xE8]))
        _ = socket.receive(atLeast: 4)

        await eventually("WebSocket messages recorded") {
            FlowStore.load().last { $0.websocket }.map { WebSocketStore.load(flowID: $0.id).count >= 2 } ?? false
        }
        let flow = try XCTUnwrap(FlowStore.load().last { $0.websocket })
        XCTAssertEqual(flow.status, 101)
        XCTAssertEqual(flow.url, "ws://127.0.0.1:\(echo.port)/chat")
        let messages = WebSocketStore.load(flowID: flow.id)
        XCTAssertEqual(messages.filter { $0.type == "text" }.map(\.direction), ["send", "receive"])
        XCTAssertEqual(messages.filter { $0.type == "text" }.map(\.text), ["hello", "echo:hello"])

        await proxy.stop()
        await pipeline.shutdown()
        await echo.stop()
    }

    func testWebSocketHandshakeDropsProxyHeadersAndCompression() {
        var headers: HTTPHeaders = ["Host": "h", "Upgrade": "websocket", "Proxy-Connection": "keep-alive",
                                    "Sec-WebSocket-Extensions": "permessage-deflate", "Proxy-Authorization": "x"]
        headers.add(name: "Connection", value: "Upgrade")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://h/ws", headers: headers)
        XCTAssertTrue(WebSocketProxy.isUpgrade(head))
        let text = WebSocketProxy.handshake(head, path: "/ws", host: "h")
        XCTAssertTrue(text.hasPrefix("GET /ws HTTP/1.1\r\n"))
        XCTAssertFalse(text.contains("Proxy-"))
        XCTAssertFalse(text.contains("Sec-WebSocket-Extensions"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }
}
