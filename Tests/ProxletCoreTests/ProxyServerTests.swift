//
//  ProxyServerTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import ProxletCore
import XCTest

/// Raw-socket tests of the listener: failure replies, access control and request bodies.
final class ProxyServerTests: ProxletTestCase {
    private func startProxy(access: AccessControl? = nil) async throws -> (ProxyServer, Int) {
        let ca = try CertificateAuthority.loadOrCreate()
        let proxy = ProxyServer(port: 0, ca: ca, pipeline: FlowPipeline(store: FlowStore()), access: access)
        try await proxy.start()
        return (proxy, try XCTUnwrap(proxy.boundPort))
    }

    /// Port 1 is never listening, so connecting to it fails at once.
    private let deadPort = 1

    func testTunnelToADeadHostAnswers502AndIsRecorded() async throws {
        let (proxy, port) = try await startProxy()
        let socket = try RawSocket(port: port)
        socket.send(Array("CONNECT 127.0.0.1:\(deadPort) HTTP/1.1\r\nHost: 127.0.0.1:\(deadPort)\r\n\r\n".utf8))
        XCTAssertTrue(socket.receiveHead().head.hasPrefix("HTTP/1.1 502"))
        await eventually("failed tunnel recorded") { FlowStore.load().last?.status == 502 }
        let flow = try XCTUnwrap(FlowStore.load().last)
        XCTAssertEqual(flow.method, "CONNECT")
        XCTAssertTrue(flow.error?.contains("Tunnel to 127.0.0.1:\(deadPort) failed") == true, flow.error ?? "nil")
        await proxy.stop()
    }

    func testWebSocketToADeadUpstreamAnswers502() async throws {
        let (proxy, port) = try await startProxy()
        let socket = try RawSocket(port: port)
        socket.send(Array("""
        GET http://127.0.0.1:\(deadPort)/chat HTTP/1.1\r
        Host: 127.0.0.1:\(deadPort)\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        \r

        """.utf8))
        let head = socket.receiveHead().head
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 502"), head)
        await proxy.stop()
    }

    func testRequestBodyIsForwardedAndRecorded() async throws {
        let upstream = try await TestUpstream.start()
        let (proxy, port) = try await startProxy()
        let socket = try RawSocket(port: port)
        let body = #"{"name":"aji"}"#
        socket.send(Array("POST http://127.0.0.1:\(upstream.port)/echo HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        XCTAssertTrue(socket.receiveHead().head.hasPrefix("HTTP/1.1 200"))
        await eventually("POST recorded") { FlowStore.load().last?.method == "POST" }
        XCTAssertEqual(FlowStore.load().last?.requestBody, body)
        await proxy.stop()
        await upstream.stop()
    }

    /// A phone on Wi-Fi is told apart by its IP: its rule answers it, while this Mac gets the general rule.
    func testMapLocalPerNetworkClientIP() async throws {
        let lan = try XCTUnwrap(SystemProxy.lanIPv4() as String?, "no LAN address")
        let upstream = try await TestUpstream.start()
        let url = "http://127.0.0.1:\(upstream.port)/v1/profile"
        try RuleStore.save(MockRule(id: "general", urlPattern: url, status: 200, body: "general"))
        try RuleStore.save(MockRule(id: "phone", urlPattern: url, status: 299, body: "phone", devices: [lan]))
        let (proxy, port) = try await startProxy()
        let request = Array("GET \(url) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)

        let phone = try RawSocket(port: port, host: lan)
        phone.send(request)
        let phoneHead = phone.receiveHead().head
        XCTAssertTrue(phoneHead.hasPrefix("HTTP/1.1 299"), phoneHead)
        XCTAssertTrue(phoneHead.contains("X-Proxlet-Mock: phone"), phoneHead)

        let mac = try RawSocket(port: port)
        mac.send(request)
        let macHead = mac.receiveHead().head
        XCTAssertTrue(macHead.hasPrefix("HTTP/1.1 200"), macHead)
        XCTAssertTrue(macHead.contains("X-Proxlet-Mock: general"), macHead)

        await eventually("both flows recorded") { FlowStore.load().count == 2 }
        let flows = FlowStore.load()
        XCTAssertEqual(flows.filter { $0.device == lan }.map(\.status), [299], "only the phone's flow carries its IP")
        XCTAssertEqual(flows.filter { $0.device == nil }.map(\.status), [200], "a local app is not tagged with an IP")
        await proxy.stop()
        await upstream.stop()
    }

    /// Connects through this Mac's Wi-Fi address, the same path a phone takes; skipped without a LAN address.
    func testNetworkClientsNeedApproval() async throws {
        let lan = try XCTUnwrap(SystemProxy.lanIPv4() as String?, "no LAN address")
        let upstream = try await TestUpstream.start()
        let access = AccessControl()
        final class Asked: @unchecked Sendable { var ips: [String] = [] }
        let asked = Asked()
        access.ask = { ip in
            asked.ips.append(ip)
            return false
        }
        let (proxy, port) = try await startProxy(access: access)
        let request = Array("GET http://127.0.0.1:\(upstream.port)/echo HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)

        let denied = try RawSocket(port: port, host: lan)
        denied.send(request)
        XCTAssertEqual(denied.receive(atLeast: 1), [], "a denied device is disconnected without a reply")
        XCTAssertEqual(asked.ips, [lan])

        let local = try RawSocket(port: port)
        local.send(request)
        XCTAssertTrue(local.receiveHead().head.hasPrefix("HTTP/1.1 200"), "this Mac is never asked")

        access.add(lan)
        let allowed = try RawSocket(port: port, host: lan)
        allowed.send(request)
        XCTAssertTrue(allowed.receiveHead().head.hasPrefix("HTTP/1.1 200"))
        XCTAssertEqual(asked.ips, [lan], "asked once")
        await proxy.stop()
        await upstream.stop()
    }
}
