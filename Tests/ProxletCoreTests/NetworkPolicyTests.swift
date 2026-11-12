//
//  NetworkPolicyTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import ProxletCore
import XCTest

/// Who may use the proxy (`AccessControl`) and which hosts are decrypted (`SSLProxying`).
final class NetworkPolicyTests: ProxletTestCase {
    func testAccessControlAsksOncePerDeviceAndRemembers() async {
        final class Asks: @unchecked Sendable {
            let lock = NSLock()
            var ips: [String] = []
        }
        let asks = Asks()
        let access = AccessControl()
        XCTAssertEqual(access.mode, .ask)
        access.ask = { ip in
            asks.lock.withLock { asks.ips.append(ip) }
            try? await Task.sleep(for: .milliseconds(50))
            return ip == "192.168.1.20"
        }
        for local in ["127.0.0.1", "::1", "::ffff:127.0.0.1"] {
            let ok = await access.isAllowed(local)
            XCTAssertTrue(ok, local)
        }

        // Three parallel connections from one phone share one prompt.
        async let a = access.isAllowed("192.168.1.20")
        async let b = access.isAllowed("192.168.1.20")
        async let c = access.isAllowed("192.168.1.20")
        let results = await [a, b, c]
        XCTAssertEqual(results, [true, true, true])
        let denied = await access.isAllowed("10.0.0.9")
        let deniedAgain = await access.isAllowed("10.0.0.9")
        XCTAssertFalse(denied)
        XCTAssertFalse(deniedAgain, "a denied device isn't asked again")
        XCTAssertEqual(asks.ips, ["192.168.1.20", "10.0.0.9"], "this Mac is never asked")

        let reloaded = AccessControl()
        XCTAssertEqual(reloaded.allowed, ["192.168.1.20"], "allowed devices are saved; denials are not")
        let deniedAfterRestart = await reloaded.isAllowed("10.0.0.9")
        XCTAssertFalse(deniedAfterRestart, "no prompt handler means deny")
        reloaded.mode = .allowAll
        let anyone = await reloaded.isAllowed("10.0.0.9")
        XCTAssertTrue(anyone)
        reloaded.remove(["192.168.1.20"])
        XCTAssertEqual(AccessControl().allowed, [])
        XCTAssertEqual(AccessControl().mode, .allowAll)
    }

    func testAccessControlManualAdd() async {
        let access = AccessControl()
        XCTAssertTrue(access.add(" 192.168.1.30 "), "surrounding spaces are trimmed")
        XCTAssertTrue(access.add("fe80::1"))
        XCTAssertFalse(access.add("192.168.1.30"), "duplicate")
        for bad in ["", "192.168.1", "192.168.1.300", "phone.local", "1.2.3.4:9191"] {
            XCTAssertFalse(access.add(bad), bad)
        }
        XCTAssertEqual(AccessControl().allowed, ["192.168.1.30", "fe80::1"])

        // Adding by hand lifts a denial from the connection prompt.
        access.ask = { _ in false }
        let denied = await access.isAllowed("10.0.0.9")
        XCTAssertFalse(denied)
        access.add("10.0.0.9")
        let allowed = await access.isAllowed("10.0.0.9")
        XCTAssertTrue(allowed)
    }

    func testSSLProxyingListMatchesIncludeMinusExclude() throws {
        var list = SSLProxying()
        XCTAssertFalse(list.shouldDecrypt("api.example.com"), "empty by default: nothing is decrypted")
        XCTAssertTrue(list.add("https://API.Example.com:8443/v1/x"), "pasted URLs are reduced to the host")
        XCTAssertEqual(list.include, [SSLProxying.Entry(domain: "api.example.com")])
        XCTAssertTrue(list.shouldDecrypt("API.example.com"))
        XCTAssertFalse(list.shouldDecrypt("www.example.com"))
        XCTAssertFalse(list.add("not a host"))
        XCTAssertFalse(list.add(""))

        list.add("*.acme.test")
        XCTAssertTrue(list.shouldDecrypt("api.acme.test"))
        list.add("pay.acme.test", to: .exclude)
        XCTAssertFalse(list.shouldDecrypt("pay.acme.test"), "exclude wins")
        list.setEnabled(false, domain: "pay.acme.test", list: .exclude)
        XCTAssertTrue(list.shouldDecrypt("pay.acme.test"), "a disabled entry is ignored")
        list.setEnabled(false, domain: "*.acme.test")
        XCTAssertFalse(list.shouldDecrypt("api.acme.test"))
        list.add("*.acme.test")
        XCTAssertEqual(list.include.count, 2, "adding an existing domain re-enables it")
        XCTAssertTrue(list.shouldDecrypt("api.acme.test"))
        XCTAssertTrue(list.remove("api.example.com"))
        XCTAssertFalse(list.remove("api.example.com"))
        list.add("api.acme.test")
        list.disableIncludes(matching: "API.acme.test")
        XCTAssertFalse(list.shouldDecrypt("api.acme.test"), "both the host and its *. pattern are turned off")
        XCTAssertEqual(list.include.map(\.enabled), [false, false])
        list.add("*.acme.test")

        XCTAssertEqual(SSLProxying.load(), SSLProxying(), "no file yet")
        try SSLProxying.update { $0 = list }
        XCTAssertEqual(SSLProxying.load(), list)
        try SSLProxying.update { $0.add("*", to: .include) }
        XCTAssertTrue(SSLProxying.load().shouldDecrypt("anything.test"), "edits are seen by the next load")
    }

    func testSSLProxyingNormalizesPortsAndRejectsJunk() {
        XCTAssertEqual(SSLProxying.normalize("API.test:8443"), "api.test")
        XCTAssertEqual(SSLProxying.normalize(" *.Acme.test "), "*.acme.test")
        XCTAssertNil(SSLProxying.normalize("api test"))
        XCTAssertNil(SSLProxying.normalize("https://"))
    }

    func testAccessListEditedByAnotherProcessIsSeen() async {
        let app = AccessControl()
        let mcp = AccessControl()  // proxlet-mcp keeps its own instance over the same access.json
        XCTAssertTrue(mcp.add("192.168.1.40"))
        XCTAssertEqual(app.allowed, ["192.168.1.40"])
        let allowed = await app.isAllowed("192.168.1.40")
        XCTAssertTrue(allowed, "no prompt for a device allowed elsewhere")
        mcp.mode = .allowAll
        XCTAssertEqual(app.mode, .allowAll)
        app.remove(["192.168.1.40"])
        XCTAssertEqual(mcp.allowed, [])
    }
}
