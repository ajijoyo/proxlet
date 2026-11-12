//
//  RuleTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import ProxletCore
import XCTest

final class RuleTests: ProxletTestCase {
    func testRuleMatching() {
        let rule = MockRule(method: "GET", urlPattern: "https://api.example.com/users/*")
        XCTAssertTrue(rule.matches(method: "get", url: "https://api.example.com/users/42?x=1"))
        XCTAssertFalse(rule.matches(method: "POST", url: "https://api.example.com/users/42"))
        XCTAssertFalse(rule.matches(method: "GET", url: "https://api.example.com/users"))
        XCTAssertFalse(MockRule(urlPattern: "https://a.com/x.json").matches(method: "GET", url: "https://a.com/xxjson"))
        var off = rule
        off.enabled = false
        XCTAssertFalse(off.matches(method: "GET", url: "https://api.example.com/users/1"))
    }

    func testRegexRule() {
        let rule = MockRule(urlPattern: #"^https://[a-z]+\.acme\.test/api/"#, useRegex: true)
        XCTAssertTrue(rule.matches(method: "GET", url: "https://api.acme.test/api/v2"))
        XCTAssertFalse(rule.matches(method: "GET", url: "https://api.acme.test/web"))
        XCTAssertFalse(MockRule(urlPattern: "([", useRegex: true).matches(method: "GET", url: "https://x"))
    }

    func testRuleStoreRoundTripAndLenientDecode() throws {
        try RuleStore.save(MockRule(id: "a", urlPattern: "https://x/*", status: 404, body: "nope"))
        try #"{"id":"b","urlPattern":"https://y/*"}"#.write(
            to: Paths.rules.appendingPathComponent("b.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RuleStore.match(method: "GET", url: "https://x/1")?.status, 404)
        XCTAssertEqual(RuleStore.match(method: "PUT", url: "https://y/1")?.status, 200)
        try RuleStore.delete(try XCTUnwrap(RuleStore.load().first { $0.id == "a" }))
        XCTAssertNil(RuleStore.match(method: "GET", url: "https://x/1"))
    }

    func testCreationDatesRoundTrip() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        try RuleStore.save(MockRule(id: "dated", urlPattern: "https://x/*", createdAt: created))
        XCTAssertEqual(RuleStore.load().first { $0.id == "dated" }?.createdAt, created)
        try #"{"id":"old","urlPattern":"https://y/*"}"#.write(
            to: Paths.rules.appendingPathComponent("old.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(RuleStore.load().first { $0.id == "old" }?.createdAt)
        let imported = try MapLocalArchive.importRules(MapLocalArchive.export(RuleStore.load()))
        XCTAssertTrue(imported.allSatisfy { $0.createdAt != nil })

        var meta = ScriptMeta()
        meta.created = created
        XCTAssertEqual(ScriptMeta.parse(meta.render(code: "")).0.created, created)
        XCTAssertNil(ScriptMeta.parse(ScriptMeta().render(code: "")).0.created)
        let file = try ScriptStore.create(fileName: "s.js", meta: ScriptMeta(), code: "")
        XCTAssertNotNil(ScriptStore.list().first { $0.fileName == file }?.meta.created)
    }

    func testHandNamedRuleFileIsUpdatedAndDeletedInPlace() throws {
        let file = Paths.rules.appendingPathComponent("login-mock.json")
        try #"{"id":"abc","urlPattern":"https://login/*","status":401}"#.write(to: file, atomically: true, encoding: .utf8)
        var rule = try XCTUnwrap(RuleStore.load().first)
        XCTAssertEqual(rule.sourceFile?.lastPathComponent, "login-mock.json")
        XCTAssertEqual(RuleStore.file(for: rule), rule.sourceFile)

        rule.enabled = false
        try RuleStore.save(rule)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: Paths.rules.path), ["login-mock.json"], "no duplicate abc.json")
        XCTAssertFalse(try XCTUnwrap(RuleStore.load().first).enabled)

        try RuleStore.delete(try XCTUnwrap(RuleStore.load().first))
        XCTAssertTrue(RuleStore.load().isEmpty)
    }

    func testRuleFromFlowDropsEncodingHeadersAndFlagsPlaceholders() {
        let headers = [Header(name: "Content-Encoding", value: "br"), Header(name: "Content-Length", value: "9"),
                       Header(name: "Content-Type", value: "application/json")]
        let flow = Flow(request: ProxyRequest(method: "GET", url: "https://a/x", headers: [], body: Data()),
                        response: ProxyResponse(status: 200, headers: headers, body: Data(#"{"a":1}"#.utf8)),
                        startedAt: Date(), mocked: false, error: nil)
        XCTAssertEqual(MockRule(flow: flow).headers, ["Content-Type": "application/json"])
        XCTAssertFalse(flow.hasPartialResponseBody)

        let image = self.flow("https://a/img.png", responseBody: Data([0xFF, 0xD8, 0xFF, 0x00]))
        XCTAssertTrue(image.hasPartialResponseBody)
        let huge = self.flow("https://a/big", responseBody: Data(repeating: 0x61, count: 1_000_001))
        XCTAssertTrue(huge.hasPartialResponseBody)
    }

    func testMockResponsesAreNotCacheable() {
        let res = MockRule(urlPattern: "*", headers: ["Cache-Control": "max-age=60", "ETag": "x"]).response()
        XCTAssertTrue(res.headers.contains(Header(name: "Cache-Control", value: "no-store")))
        XCTAssertFalse(res.headers.contains { $0.name == "ETag" })
    }

    func testBinaryMapLocalFromImageFlowAndFiles() async throws {
        let upstream = try await TestUpstream.start()
        let pipeline = FlowPipeline(store: FlowStore())
        _ = await pipeline.handle(get: "http://127.0.0.1:\(upstream.port)/image")
        await upstream.stop()
        let flow = try XCTUnwrap(FlowStore.load().last)

        // A captured image becomes a rule backed by a copy in map-local-files/, served byte for byte.
        let rule = try XCTUnwrap(try MockRule.from(flow: flow, urlPattern: "https://cdn.test/logo.png"))
        let owned = try XCTUnwrap(rule.bodyFile)
        XCTAssertTrue(owned.hasPrefix(Paths.mapLocalFiles.path) && owned.hasSuffix(".png"), owned)
        try RuleStore.save(rule)
        let mocked = await pipeline.handle(get: "https://cdn.test/logo.png")
        XCTAssertEqual(mocked.body, TestUpstream.png)
        XCTAssertEqual(mocked.headers.first { $0.name.lowercased() == "content-type" }?.value, "image/png")

        // A user's own file without a Content-Type header is typed by its extension and survives rule deletion.
        let own = Paths.root.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0x00]).write(to: own)
        let fileRule = MockRule(name: "jpg", urlPattern: "https://cdn.test/photo", headers: [:], bodyFile: own.path)
        XCTAssertEqual(fileRule.response().headers.first { $0.name == "Content-Type" }?.value, "image/jpeg")
        XCTAssertEqual(fileRule.response().body, Data([0xFF, 0xD8, 0xFF, 0x00]))

        // Export inlines text bodies only; binary ones keep their path instead of being corrupted.
        let textFile = Paths.root.appendingPathComponent("body.json")
        try Data(#"{"a":1}"#.utf8).write(to: textFile)
        let textRule = MockRule(name: "t", urlPattern: "https://x/*", bodyFile: textFile.path)
        let exported = try MapLocalArchive.importRules(MapLocalArchive.export([fileRule, textRule]))
        XCTAssertEqual(exported[0].bodyFile, own.path)
        XCTAssertNil(exported[1].bodyFile)
        XCTAssertEqual(exported[1].body, #"{"a":1}"#)

        try RuleStore.delete(RuleStore.load()[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned), "Proxlet's copy goes with the rule")
        try RuleStore.save(fileRule)
        try RuleStore.delete(fileRule)
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path), "a user's file is never deleted")

        // Only a placeholder and no stored bytes: no rule.
        var placeholder = flow
        placeholder.id = "no-bytes"
        XCTAssertNil(try MockRule.from(flow: placeholder))
    }
}

extension RuleTests {
    func testMapLocalDelayHoldsTheMockResponse() async throws {
        try RuleStore.save(MockRule(urlPattern: "https://slow.test/*", body: "late", delayMs: 300))
        try RuleStore.save(MockRule(urlPattern: "https://fast.test/*", body: "now"))
        let pipeline = FlowPipeline(store: FlowStore())

        var start = Date()
        let slow = await pipeline.handle(get: "https://slow.test/x")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
        XCTAssertEqual(String(decoding: slow.body, as: UTF8.self), "late")
        XCTAssertGreaterThanOrEqual(FlowStore.load().last?.durationMs ?? 0, 300, "the recorded duration includes the delay")

        start = Date()
        _ = await pipeline.handle(get: "https://fast.test/x")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2, "no delay means immediately")
    }

    func testDelayIsOptionalInRuleFiles() throws {
        let old = try JSONDecoder().decode(MockRule.self, from: Data(#"{"id":"a","urlPattern":"https://a/*"}"#.utf8))
        XCTAssertNil(old.delayMs, "rules written before delays existed answer immediately")
        let encoded = String(decoding: try RuleStore.encoder.encode(MockRule(urlPattern: "https://a/*")), as: UTF8.self)
        XCTAssertFalse(encoded.contains("delayMs"), "no delay, no key")
        let delayed = try RuleStore.encoder.encode(MockRule(urlPattern: "https://a/*", delayMs: 1500))
        XCTAssertEqual(try RuleStore.decoder.decode(MockRule.self, from: delayed).delayMs, 1500)
    }
}

extension RuleTests {
    func testMapLocalRunsFirstThenOnResponseScripts() async throws {
        let upstream = try await TestUpstream.start()
        let url = "http://127.0.0.1:\(upstream.port)/echo"
        try RuleStore.save(MockRule(urlPattern: url + "*", status: 200, headers: ["Content-Type": "application/json"],
                                    body: #"{"source":"mock"}"#, delayMs: 50))
        try writeScript("edit.js", """
        // @match \(url)*
        function onRequest(req) { req.headers["X-From-Script"] = "request"; return req; }
        function onResponse(req, res) {
          var body = JSON.parse(res.body);
          body.scripted = true;
          res.body = JSON.stringify(body);
          res.headers["X-Script"] = "1";
          res.status = 201;
          return res;
        }
        """)
        let pipeline = FlowPipeline(store: FlowStore())

        // Both on: the mock answers (the server is never asked), then onResponse edits that mock.
        let both = await pipeline.handle(get: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: both.body) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "mock", "Map Local supplied the body")
        XCTAssertEqual(json["scripted"] as? Bool, true, "then the script changed it")
        XCTAssertEqual(both.status, 201)
        XCTAssertEqual(both.headers.first { $0.name == "X-Script" }?.value, "1")
        XCTAssertNotNil(both.headers.first { $0.name == "X-Proxlet-Mock" })
        XCTAssertNil(json["headers"], "the upstream echo never ran, so onRequest had nothing to send")
        let flow = try XCTUnwrap(FlowStore.load().last)
        XCTAssertTrue(flow.mocked)
        XCTAssertEqual(flow.scripts, ["edit.js"])

        // Scripts off: the plain mock.
        pipeline.scriptsEnabled = false
        let mockOnly = await pipeline.handle(get: url)
        XCTAssertEqual(String(decoding: mockOnly.body, as: UTF8.self), #"{"source":"mock"}"#)
        XCTAssertEqual(mockOnly.status, 200)

        // Map Local off: the request reaches the server and both script phases run on the real traffic.
        pipeline.scriptsEnabled = true
        pipeline.mapLocalEnabled = false
        let live = await pipeline.handle(get: url)
        let echoed = try XCTUnwrap(JSONSerialization.jsonObject(with: live.body) as? [String: Any])
        XCTAssertEqual((echoed["headers"] as? [String: String])?["x-from-script"], "request")
        XCTAssertEqual(echoed["scripted"] as? Bool, true)
        XCTAssertFalse(try XCTUnwrap(FlowStore.load().last).mocked)
        await upstream.stop()
    }
}

private extension FlowPipeline {
    func handle(get url: String) async -> ProxyResponse {
        await handle(ProxyRequest(method: "GET", url: url, headers: [], body: Data()))
    }
}
