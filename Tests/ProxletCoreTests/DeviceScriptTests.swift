//
//  DeviceScriptTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 15/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import ProxletCore
import XCTest

final class DeviceScriptTests: ProxletTestCase {
    func testDeviceTargetsRoundTripAndLegacyGlobal() throws {
        let uuid = "12345678-abcd-1234-abcd-123456789abc"
        var meta = ScriptMeta()
        meta.devices = try MockRule.devices([uuid, "192.168.1.42", "::1"])
        let (parsed, code) = ScriptMeta.parse(meta.render(code: "function onRequest(req) { return req; }"))
        XCTAssertEqual(parsed, meta)
        XCTAssertTrue(code.hasPrefix("function"))
        for device in [uuid, "192.168.1.42", "::1"] {
            XCTAssertTrue(parsed.matches(method: "GET", url: "https://x/", device: device))
        }
        XCTAssertFalse(parsed.matches(method: "GET", url: "https://x/"))
        XCTAssertFalse(parsed.matches(method: "GET", url: "https://x/", device: "192.168.1.43"))
        let global = ScriptMeta.parse("// @name Legacy\nfunction onRequest(req) { return req; }").0
        XCTAssertTrue(global.matches(method: "GET", url: "https://x/"))
        meta.devices = nil
        XCTAssertFalse(meta.render(code: "").contains("@devices"))
    }

    func testDeviceScriptsOnlyTransformMatchingClients() throws {
        try writeScript("device.js", """
        // @devices 192.168.1.42
        function onRequest(req) { req.headers["X-Device"] = "yes"; return req; }
        function onResponse(req, res) { res.status = 299; return res; }
        """)
        let engine = ScriptEngine()
        for device in [nil, "192.168.1.43", "192.168.1.42"] as [String?] {
            let matches = device == "192.168.1.42"
            let req = ProxyRequest(method: "GET", url: "https://x/", headers: [], body: Data(), clientDevice: device)
            XCTAssertEqual(engine.hasMatch(method: req.method, url: req.url, device: device), matches)
            XCTAssertEqual(engine.onRequest(req).value.headers.contains(Header(name: "X-Device", value: "yes")), matches)
            XCTAssertEqual(engine.onResponse(req, ProxyResponse(status: 200, headers: [], body: Data())).value.status, matches ? 299 : 200)
        }
    }

}
