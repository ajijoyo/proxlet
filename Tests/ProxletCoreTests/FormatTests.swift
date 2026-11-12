//
//  FormatTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import ProxletCore
import XCTest

final class FormatTests: ProxletTestCase {
    private func sampleFlows() -> [Flow] {
        let api = Flow(request: ProxyRequest(method: "POST", url: "https://api.example.com/users?x=1",
                                             headers: [Header(name: "Content-Type", value: "application/json")],
                                             body: Data(#"{"name":"aji"}"#.utf8)),
                       response: ProxyResponse(status: 201, headers: [Header(name: "Content-Type", value: "application/json")],
                                               body: Data(#"{"id":7}"#.utf8)),
                       startedAt: Date(timeIntervalSince1970: 1_800_000_000.25), mocked: false, error: nil)
        let ws = Flow(request: ProxyRequest(method: "GET", url: "wss://ws.example.com/socket", headers: [], body: Data()),
                      response: ProxyResponse(status: 101, headers: [], body: Data()), startedAt: Date(), mocked: false,
                      error: nil, websocket: true)
        WebSocketStore.append(WebSocketMessage(time: Date(), direction: "send", type: "text", size: 5, text: "hello"), flowID: ws.id)
        return [api, ws]
    }

    func testHARRoundTrip() throws {
        let flows = sampleFlows()
        let data = try SessionArchive.encodeHAR(flows)
        let back = try SessionArchive.decodeHAR(data)
        XCTAssertEqual(back.count, 2)
        let api = back[0].flow
        XCTAssertEqual([api.method, api.url, api.requestBody, api.responseBody], ["POST", flows[0].url, #"{"name":"aji"}"#, #"{"id":7}"#])
        XCTAssertEqual(api.status, 201)
        XCTAssertEqual(api.startedAt.timeIntervalSince1970, flows[0].startedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(back[1].flow.websocket)
        XCTAssertEqual(back[1].messages.map(\.text), ["hello"])
        let entry = try XCTUnwrap(((JSONSerialization.jsonObject(with: data) as? [String: Any])?["log"] as? [String: Any])?["entries"] as? [[String: Any]])
        XCTAssertEqual((entry[0]["response"] as? [String: Any])?["statusText"] as? String, "Created")
    }

    func testCharlesSessionRoundTrip() throws {
        try XCTSkipIf(CharlesConverter.executable == nil, "Charles not installed")
        let url = Paths.root.appendingPathComponent("session.chls")
        try SessionArchive.export(sampleFlows(), to: url)
        XCTAssertEqual([UInt8](try Data(contentsOf: url).prefix(2)), [0xAC, 0xED], "Java serialization stream")
        let back = try SessionArchive.importFile(url)
        let api = try XCTUnwrap(back.first { $0.flow.method == "POST" }).flow
        XCTAssertEqual(api.url, "https://api.example.com/users?x=1")
        XCTAssertEqual(api.status, 201)
        XCTAssertEqual(api.responseBody, #"{"id":7}"#)
        XCTAssertEqual(api.requestBody, #"{"name":"aji"}"#)
    }

    func testHTTPMessageRoundTripAndBeautify() throws {
        let text = HTTPMessageFormat.render(status: 201, headers: ["Content-Type": "application/json", "X-A": "1"], body: "{\"a\":1}\n\nmore")
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 201 Created\n"))
        let parsed = try XCTUnwrap(HTTPMessageFormat.parse(text))
        XCTAssertEqual(parsed.status, 201)
        XCTAssertEqual(parsed.headers, ["Content-Type": "application/json", "X-A": "1"])
        XCTAssertEqual(parsed.body, "{\"a\":1}\n\nmore")
        XCTAssertNil(HTTPMessageFormat.parse("200 OK\n\nbody"))
        XCTAssertEqual(HTTPMessageFormat.parse("HTTP/1.1 404 Not Found\r\n\r\n")?.status, 404)

        let pretty = HTTPMessageFormat.beautify("HTTP/1.1 200 OK\nX-A: 1\n\n{\"b\":[1]}")
        XCTAssertEqual(HTTPMessageFormat.parse(pretty)?.headers, ["X-A": "1"])
        XCTAssertTrue(try XCTUnwrap(HTTPMessageFormat.parse(pretty)).body.contains("\n"))
        XCTAssertEqual(HTTPMessageFormat.beautify("HTTP/1.1 200 OK\n\nplain text"), "HTTP/1.1 200 OK\n\nplain text")
    }

    func testJSONFormatterPrettyPrintsOnlyObjectsAndArrays() {
        XCTAssertEqual(JSONFormatter.pretty(#"{"b":1,"a":"x/y"}"#), "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
        XCTAssertEqual(JSONFormatter.pretty("  [1,2]"), "[\n  1,\n  2\n]")
        XCTAssertNil(JSONFormatter.pretty("42"), "scalars are left alone")
        XCTAssertNil(JSONFormatter.pretty("{broken"))
        XCTAssertNil(JSONFormatter.pretty(""))
    }

    func testHTTPReasonPhrases() {
        XCTAssertEqual(HTTPReason.phrase(200), "OK")
        XCTAssertEqual(HTTPReason.phrase(404), "Not Found")
        XCTAssertEqual(HTTPReason.phrase(418), "I'm a teapot")
    }

    func testProxymanMapLocalFileImportExport() throws {
        let file = Paths.root.appendingPathComponent("cdn.acme.test_9B106283.json")
        try """
        HTTP/1.1 200 OK
        Server: nginx
        Content-Type: application/json

        {
          "rooms": [{"_id": 66289871}]
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        let rule = try XCTUnwrap(HTTPMessageFormat.rule(fromFile: file))
        XCTAssertEqual(rule.urlPattern, "https://cdn.acme.test/*")
        XCTAssertEqual(rule.name, "cdn.acme.test_9B106283")
        XCTAssertEqual(rule.headers["Server"], "nginx")
        XCTAssertTrue(rule.body.contains(#""_id": 66289871"#))

        let noHost = Paths.root.appendingPathComponent("response_ABC.json")
        try "{}".write(to: noHost, atomically: true, encoding: .utf8)
        XCTAssertEqual(HTTPMessageFormat.rule(fromFile: noHost)?.urlPattern, "https://example.com/*")

        let f = flow("https://cdn.acme.test/api/v1/rooms?x=1", responseBody: Data(#"{"a":1}"#.utf8))
        let exported = HTTPMessageFormat.render(response: f)
        XCTAssertTrue(exported.hasPrefix("HTTP/1.1 200 OK\n"))
        XCTAssertTrue(HTTPMessageFormat.fileName(for: f).hasPrefix("cdn.acme.test_"))
        XCTAssertEqual(HTTPMessageFormat.fileName(host: "", id: "abcdef123"), "response_ABCDEF12.json")
    }

    func testPlainBodyFileFallback() {
        let raw = HTTPMessageFormat.parseFile("{\n  \"status\": true\n}", pathExtension: "json")
        XCTAssertEqual(raw.status, 200)
        XCTAssertEqual(raw.headers["Content-Type"], "application/json")
        XCTAssertEqual(raw.body, "{\n  \"status\": true\n}")
        XCTAssertEqual(HTTPMessageFormat.parseFile("HTTP/1.1 404 Not Found\n\nx", pathExtension: "txt").status, 404)
    }

    func testMapLocalArchiveRoundTrip() throws {
        let file = Paths.root.appendingPathComponent("body.json")
        try #"{"from":"file"}"#.write(to: file, atomically: true, encoding: .utf8)
        let rules = [MockRule(name: "a", method: "GET", urlPattern: "https://x/*", status: 404, body: "nope"),
                     MockRule(name: "b", urlPattern: "^https://y/.*", useRegex: true, bodyFile: file.path)]
        let back = try MapLocalArchive.importRules(MapLocalArchive.export(rules))
        XCTAssertEqual(back.map(\.name), ["a", "b"])
        XCTAssertEqual(back[0].status, 404)
        XCTAssertTrue(back[1].useRegex)
        XCTAssertEqual(back[1].body, #"{"from":"file"}"#, "bodyFile is inlined")
        XCTAssertNil(back[1].bodyFile)
        XCTAssertNotEqual(back[0].id, rules[0].id, "imports get fresh ids")
    }

    func testImportProxymanRuleTreeWithFolders() throws {
        let response = Paths.root.appendingPathComponent("mcp_maplocal_TEST.txt")
        try "HTTP/1.1 201 Created\nContent-Type: application/json\n\n{\"ok\":true}".write(to: response, atomically: true, encoding: .utf8)
        let leaf: [String: Any] = ["nodeType": ["node": ["_0": [
            "id": "42D9FD4A", "name": "Room meta", "url": "https://api.acme.test/api/v2/feeds/meta/1001*",
            "regex": "useWildcard", "method": ["exact": [["name": "GET"]]], "isEnabled": false,
            "localFile": ["path": response.path, "name": "Room meta"]]]]]
        let any: [String: Any] = ["nodeType": ["node": ["_0": [
            "id": "X", "name": "any", "url": "*/user/*", "regex": "useWildcard", "method": ["any": [:]], "isEnabled": true]]]]
        let tree: [String: Any] = ["nodes": [leaf, ["nodeType": ["folder": ["nodes": [any]]]]]]
        let rules = try MapLocalArchive.importRules(JSONSerialization.data(withJSONObject: tree))
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].name, "Room meta")
        XCTAssertEqual(rules[0].method, "GET")
        XCTAssertFalse(rules[0].enabled)
        XCTAssertEqual(rules[0].status, 201)
        XCTAssertEqual(rules[0].body, #"{"ok":true}"#)
        XCTAssertNil(rules[1].method)
        XCTAssertEqual(rules[1].urlPattern, "*/user/*")
    }

    func testProxymanScriptConfigRoundTrip() throws {
        let tree: [String: Any] = ["tree": [["nodeType": ["node": ["_0": [
            "name": "Mock items badge", "url": "*/feeds/*/items*", "regex": "useWildcard",
            "method": ["exact": [["name": "GET"]]], "isEnabled": false, "isEnableRequest": false, "isEnableResponse": true,
            "isMockResponse": false, "fileContent": ScriptTests.proxymanScript, "id": "89010900"]]]]],
            "entries": NSNull(), "userFiles": [["name": "HelloWorld.js", "data": "eA=="]]]
        let gz = try XCTUnwrap(ContentDecoding.gzip(JSONSerialization.data(withJSONObject: tree)))
        let imported = try Proxyman.ScriptConfig.importConfig(gz)
        XCTAssertEqual(imported.scripts.map(\.fileName), ["mock-items-badge.js"])
        XCTAssertEqual(imported.notes.count, 1, "userFiles are reported")
        let (meta, code) = ScriptMeta.parse(imported.scripts[0].source)
        XCTAssertEqual(meta.name, "Mock items badge")
        XCTAssertEqual(meta.method, "GET")
        XCTAssertFalse(meta.enabled)
        XCTAssertFalse(meta.onRequest)
        XCTAssertEqual(code, ScriptTests.proxymanScript)

        let file = Paths.scripts.appendingPathComponent(imported.scripts[0].fileName)
        try imported.scripts[0].source.write(to: file, atomically: true, encoding: .utf8)
        let exported = try Proxyman.ScriptConfig.exportConfig([file])
        XCTAssertEqual([UInt8](exported.prefix(2)), [0x1f, 0x8b])
        let again = try Proxyman.ScriptConfig.importConfig(exported, existing: ["mock-items-badge.js"])
        XCTAssertEqual(again.scripts[0].fileName, "mock-items-badge-2.js")
        XCTAssertEqual(ScriptMeta.parse(again.scripts[0].source).0, meta)
    }

    func testContentDecoding() throws {
        let expected = Data(#"{"hello":"proxlet"}"#.utf8)
        let fixtures = [
            ("gzip", "H4sIAGhQ9GoC/6tWykjNyclXslIqKMqvyEktUaoFAHXg1HUTAAAA"),
            ("deflate", "eJyrVspIzcnJV7JSKijKr8hJLVGqBQBDPwbd"),
            ("deflate", "q1bKSM3JyVeyUiooyq/ISS1RqgUA"),
            ("br", "DwmAeyJoZWxsbyI6InByb3hsZXQifQM="),
        ]
        for (encoding, b64) in fixtures {
            XCTAssertEqual(ContentDecoding.decode(try XCTUnwrap(Data(base64Encoded: b64)), encoding: encoding), expected, encoding)
        }
        XCTAssertEqual(ContentDecoding.decode(Data(), encoding: "gzip"), Data())
        XCTAssertNil(ContentDecoding.decode(Data("not gzip at all, really".utf8), encoding: "gzip"))
        XCTAssertNil(ContentDecoding.decode(Data([1, 2, 3]), encoding: "zstd"))
        let data = Data((0..<5000).map { UInt8($0 % 251) })
        XCTAssertEqual(ContentDecoding.gunzip(try XCTUnwrap(ContentDecoding.gzip(data))), data)
    }

    func testWebSocketFrameParser() {
        let parser = FrameParser()
        // Masked client text frame "hi" split across two reads.
        let mask: [UInt8] = [1, 2, 3, 4]
        let payload = Array("hi".utf8).enumerated().map { $0.element ^ mask[$0.offset % 4] }
        let frame: [UInt8] = [0x81, 0x80 | 2] + mask + payload
        XCTAssertTrue(parser.feed(Array(frame.prefix(3))).isEmpty)
        let first = parser.feed(Array(frame.dropFirst(3)))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].0, "text")
        XCTAssertEqual(String(decoding: first[0].1, as: UTF8.self), "hi")
        // Fragmented text ("ab" + "c"), a 200-byte binary frame (16-bit length), a 64-bit-length frame and a close frame.
        let big = [UInt8](repeating: 7, count: 200)
        let bytes: [UInt8] = [0x01, 2] + Array("ab".utf8) + [0x80, 1] + Array("c".utf8)
            + [0x82, 126, 0, 200] + big
            + [0x82, 127, 0, 0, 0, 0, 0, 0, 0, 3] + [9, 9, 9]
            + [0x88, 2, 0x03, 0xE8]
        let rest = parser.feed(bytes)
        XCTAssertEqual(rest.map(\.0), ["text", "binary", "binary", "close"])
        XCTAssertEqual(String(decoding: rest[0].1, as: UTF8.self), "abc")
        XCTAssertEqual(rest[1].1.count, 200)
        XCTAssertEqual(rest[2].1, [9, 9, 9])
    }

    func testFrameParserSurvivesHostileLengths() {
        // Int.max length would overflow `offset + length`; it must stop parsing instead of trapping.
        let overflow = FrameParser()
        XCTAssertTrue(overflow.feed([0x82, 127, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 1, 2, 3]).isEmpty)
        XCTAssertTrue(overflow.feed([0x81, 1, 0x41]).isEmpty, "gave up for this direction")
        let negative = FrameParser()
        XCTAssertTrue(negative.feed([0x82, 127, 0xFF, 0, 0, 0, 0, 0, 0, 1]).isEmpty)
    }

    func testMalformedFilesAreRejectedWithAReason() throws {
        XCTAssertThrowsError(try SessionArchive.decodeHAR(Data(#"{"log":{}}"#.utf8))) {
            XCTAssertEqual($0.localizedDescription, "Not a HAR 1.2 file (missing log.entries).")
        }
        XCTAssertThrowsError(try Proxyman.ScriptConfig.importConfig(Data("nope".utf8))) {
            XCTAssertEqual($0.localizedDescription, "This file has no scripts Proxlet can read.")
        }
        XCTAssertThrowsError(try MapLocalArchive.importRules(Data("[1]".utf8))) {
            XCTAssertEqual($0.localizedDescription, "This file has no Map Local rules Proxlet can read.")
        }
        XCTAssertTrue(CharlesConverter.Missing().localizedDescription.contains(".har"))
    }

    func testMapLocalImportAcceptsABareRuleArrayWithFreshIDs() throws {
        let rule = MockRule(name: "a", urlPattern: "https://a/*", body: "{}")
        let imported = try MapLocalArchive.importRules(RuleStore.encoder.encode([rule]))
        XCTAssertEqual(imported.map(\.urlPattern), ["https://a/*"])
        XCTAssertNotEqual(imported[0].id, rule.id, "imports never overwrite an existing rule")
    }

    func testProxymanConfigNotesWhatCannotBeImported() throws {
        let config: [String: Any] = [
            "tree": [["nodeType": ["node": ["_0": ["name": "Mock A", "url": "*", "isMockResponse": true, "fileContent": ""]]]]],
            "userFiles": [["name": "helpers.js"]],
        ]
        let result = try Proxyman.ScriptConfig.importConfig(JSONSerialization.data(withJSONObject: config))
        XCTAssertEqual(result.scripts.count, 1, "plain JSON (not gzipped) is accepted too")
        XCTAssertEqual(result.notes.count, 2)
        XCTAssertTrue(result.notes[0].contains("Mock A"))
        XCTAssertTrue(result.notes[1].contains("helpers.js"))
    }
}
