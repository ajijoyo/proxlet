//
//  ScriptTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import ProxletCore
import XCTest

final class ScriptTests: ProxletTestCase {
    static let proxymanScript = """
    function onResponse(context, url, request, response) {
        try {
            var body = response.body;
            if (typeof body === "string") { body = JSON.parse(body); }
            if (body && Array.isArray(body.items)) {
                for (var i = 0; i < body.items.length; i++) {
                    body.items[i].badge = { "sizes": [3, 6, 12] };
                }
            }
            response.body = body;
            response.statusCode = 299;
            console.log("host " + request.host + " q " + request.queryString.os);
        } catch (e) {
            console.log("error: " + e);
        }
        return response;
    }
    """

    private func request(_ url: String = "https://x/", method: String = "GET", headers: [Header] = [], body: Data = Data()) -> ProxyRequest {
        ProxyRequest(method: method, url: url, headers: headers, body: body)
    }

    func testScriptsTransformAndKeepBinaryBody() throws {
        try writeScript("a.js", """
        function onRequest(req) { req.headers["X-Added"] = "yes"; return req; }
        function onResponse(req, res) { res.status = 418; return res; }
        """)
        let engine = ScriptEngine()
        let binary = Data([0xFF, 0xFE, 0x00])
        let req = engine.onRequest(request(body: binary))
        XCTAssertEqual(req.errors, [])
        XCTAssertTrue(req.value.headers.contains(Header(name: "X-Added", value: "yes")))
        XCTAssertEqual(req.value.body, binary)
        let res = engine.onResponse(req.value, ProxyResponse(status: 200, headers: [], body: Data("hi".utf8)))
        XCTAssertEqual(res.value.status, 418)
        XCTAssertEqual(res.value.body, Data("hi".utf8))
    }

    func testScriptErrorIsReported() throws {
        try writeScript("bad.js", "function onRequest(req) { throw new Error('boom'); }")
        let errors = ScriptEngine().onRequest(request()).errors
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("boom"))
    }

    func testScriptMetaScopesAndDisablesScript() throws {
        var meta = ScriptMeta()
        meta.name = "only v2"
        meta.match = #"^https://([a-z0-9-]+\.)+example\.com/api/v2/.*"#
        meta.useRegex = true
        meta.method = "GET"
        meta.onRequest = false
        let code = "function onResponse(req, res) { res.status = 299; return res; }"
        try writeScript("m.js", meta.render(code: code))
        let parsed = ScriptMeta.parse(meta.render(code: code))
        XCTAssertEqual(parsed.0, meta)
        XCTAssertEqual(parsed.code, code)

        let engine = ScriptEngine()
        func status(_ method: String, _ url: String) -> Int {
            engine.onResponse(request(url, method: method), ProxyResponse(status: 200, headers: [], body: Data())).value.status
        }
        XCTAssertEqual(status("GET", "https://a.b.example.com/api/v2/x"), 299)
        XCTAssertEqual(status("POST", "https://a.b.example.com/api/v2/x"), 200)
        XCTAssertEqual(status("GET", "https://a.example.com/api/v1/x"), 200)

        // Disabling rewrites only the header; the script then stops applying.
        let file = Paths.scripts.appendingPathComponent("m.js")
        try ScriptMeta.setEnabled(false, file: file)
        XCTAssertFalse(ScriptMeta.parse(try String(contentsOf: file, encoding: .utf8)).0.enabled)
        XCTAssertEqual(ScriptMeta.parse(try String(contentsOf: file, encoding: .utf8)).code, code)
        // The engine caches by modification date; move it forward instead of sleeping past the 1 s resolution.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        XCTAssertEqual(status("GET", "https://a.b.example.com/api/v2/x"), 200)
    }

    func testProxymanStyleOnResponse() throws {
        var meta = ScriptMeta()
        meta.match = "*/feeds/*/items*"
        try writeScript("items.js", meta.render(code: Self.proxymanScript))
        let req = request("https://api.acme.test/api/v1/feeds/1/items?os=ios")
        let res = ProxyResponse(status: 200, headers: [], body: Data(#"{"items":[{"id":1}]}"#.utf8))
        let out = ScriptEngine().onResponse(req, res)
        XCTAssertEqual(out.errors, [])
        XCTAssertEqual(out.applied, ["items.js"])
        XCTAssertEqual(out.value.status, 299)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: out.value.body) as? [String: [[String: Any]]])
        XCTAssertEqual((json["items"]?[0]["badge"] as? [String: [Int]])?["sizes"], [3, 6, 12])
    }

    func testProxymanStyleOnRequestRewrites() throws {
        try writeScript("x.js", """
        function onRequest(context, url, request) {
          request.headers["X-A"] = "1";
          request.body = { k: request.queryString.id, host: request.host };
          return request;
        }
        """)
        let out = ScriptEngine().onRequest(request("https://api.example.com/v1/users?id=7", method: "POST",
                                                   body: Data(#"{"old":true}"#.utf8)))
        XCTAssertEqual(out.errors, [])
        XCTAssertEqual(out.applied, ["x.js"])
        XCTAssertEqual(out.value.method, "POST")
        XCTAssertEqual(out.value.url, "https://api.example.com/v1/users?id=7")
        XCTAssertTrue(out.value.headers.contains(Header(name: "X-A", value: "1")))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: out.value.body) as? [String: String])
        XCTAssertEqual(body, ["k": "7", "host": "api.example.com"])
    }

    func testScriptPreservesDuplicateHeaders() throws {
        try writeScript("id.js", "function onResponse(req, res) { res.headers['X-New'] = 'y'; return res; }")
        let cookies = [Header(name: "Set-Cookie", value: "a=1"), Header(name: "Set-Cookie", value: "b=2"),
                       Header(name: "Content-Type", value: "text/plain")]
        let out = ScriptEngine().onResponse(request(), ProxyResponse(status: 200, headers: cookies, body: Data()))
        XCTAssertEqual(out.value.headers.filter { $0.name == "Set-Cookie" }.map(\.value), ["a=1", "b=2"])
        XCTAssertTrue(out.value.headers.contains(Header(name: "X-New", value: "y")))
    }

    func testRunawayScriptIsStoppedAndDoesNotBlockOthers() async throws {
        var hung = ScriptMeta()
        hung.match = "https://hang/*"
        try writeScript("hang.js", hung.render(code: "function onResponse(req, res) { while (true) {} }"))
        let engine = ScriptEngine()
        _ = engine.hasMatch(method: "GET", url: "https://hang/x")  // loads both contexts up front

        let started = Date()
        let stuck = Task.detached {
            engine.onResponse(ProxyRequest(method: "GET", url: "https://hang/x", headers: [], body: Data()),
                              ProxyResponse(status: 200, headers: [], body: Data()))
        }
        try await Task.sleep(for: .milliseconds(200))
        // An unrelated request must not wait on the hung script.
        let lookup = Date()
        XCTAssertFalse(engine.hasMatch(method: "GET", url: "https://other/x"))
        XCTAssertLessThan(Date().timeIntervalSince(lookup), 0.5)

        let result = await stuck.value
        XCTAssertEqual(result.errors.count, 1, "terminated by the execution time limit")
        XCTAssertLessThan(Date().timeIntervalSince(started), ScriptEngine.timeLimit + 3)
    }

    func testScriptStoreIDsAreVerbatimAndContained() throws {
        try writeScript("my.script.js", "// @name dotted\n")
        try writeScript("plain.js", "// @name plain\n")
        XCTAssertEqual(ScriptStore.list().map(\.id), ["my.script", "plain"])
        XCTAssertEqual(try ScriptStore.url(forID: "my.script").lastPathComponent, "my.script.js")
        XCTAssertEqual(try ScriptStore.url(forID: "plain.js").lastPathComponent, "plain.js")
        XCTAssertThrowsError(try ScriptStore.url(forID: "../rules/x"))
        XCTAssertThrowsError(try ScriptStore.url(forID: "missing"))
    }

    func testAddScriptFileNameDoesNotReuseAnotherURLsScript() throws {
        let first = ScriptStore.fileName(forURL: "https://h/a-b", method: "GET")
        XCTAssertFalse(first.exists)
        var meta = ScriptMeta()
        meta.match = "https://h/a-b*"
        meta.method = "GET"
        try ScriptStore.create(fileName: first.fileName, meta: meta, code: "")

        XCTAssertEqual(ScriptStore.fileName(forURL: "https://h/a-b", method: "GET").fileName, first.fileName)
        XCTAssertTrue(ScriptStore.fileName(forURL: "https://h/a-b", method: "GET").exists)
        let collision = ScriptStore.fileName(forURL: "https://h/a/b", method: "GET")
        XCTAssertFalse(collision.exists)
        XCTAssertNotEqual(collision.fileName, first.fileName)
    }

    func testBrokenScriptIsReportedNotSilentlySkipped() throws {
        try writeScript("a-broken.js", "function onResponse(req, res) { return res;")
        try writeScript("b-good.js", "function onResponse(req, res) { res.status = 201; return res; }")
        let out = ScriptEngine().onResponse(request(), ProxyResponse(status: 200, headers: [], body: Data()))
        XCTAssertEqual(out.errors.count, 1)
        XCTAssertTrue(out.errors[0].hasPrefix("a-broken.js: failed to load"), out.errors[0])
        XCTAssertEqual(out.value.status, 201, "other scripts still run")
        XCTAssertEqual(out.applied, ["b-good.js"])
    }

    func testNonJSONBodiesAndNullResultsAreLeftAlone() throws {
        try writeScript("p.js", """
        function onResponse(context, url, request, response) { response.body = response.body + "!"; return response; }
        function onRequest(req) { return null; }
        """)
        let engine = ScriptEngine()
        let res = engine.onResponse(request(), ProxyResponse(status: 200, headers: [], body: Data("plain".utf8)))
        XCTAssertEqual(String(decoding: res.value.body, as: UTF8.self), "plain!", "a non-JSON body reaches Proxyman scripts as text")
        let req = engine.onRequest(request(body: Data("x".utf8)))
        XCTAssertEqual(req.applied, [], "returning null means no change")
        XCTAssertEqual(req.value.body, Data("x".utf8))
    }
}
