//
//  SyntaxTests.swift
//  ProxletTests
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import Proxlet
import ProxletCore
import XCTest

final class SyntaxTests: XCTestCase {
    override func setUpWithError() throws {
        // Theme.current reads and writes theme.json, so keep it away from the real data folder.
        Paths.root = FileManager.default.temporaryDirectory.appendingPathComponent("proxlet-ui-test-\(UUID().uuidString)")
        try Paths.ensure()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: Paths.root)
    }

    func testSyntaxSpans() {
        func tokens(_ text: String, _ kind: SyntaxKind) -> [String: Token] {
            var out: [String: Token] = [:]
            for (r, t) in Syntax.spans(text, kind: kind) { out[(text as NSString).substring(with: r)] = t }
            return out
        }
        let j = tokens(#"{"id": 12, "ok": true, "s": "v 3"}"#, .json)
        XCTAssertEqual(j[#""id""#], .key)
        XCTAssertEqual(j["12"], .number)
        XCTAssertEqual(j["true"], .literal)
        XCTAssertEqual(j[#""v 3""#], .string)
        let nested = #"{"a": [{"s": "{x}"}]}"#
        let depths = Syntax.spans(nested, kind: .json).compactMap { r, t -> String? in
            guard case .bracket(let d) = t else { return nil }
            return (nested as NSString).substring(with: r) + "\(d)"
        }
        XCTAssertEqual(depths, ["{0", "[1", "{2", "}2", "]1", "}0"])

        let h = tokens("HTTP/1.1 200\nContent-Type: application/json\n\n{\"a\": 1}", .http)
        XCTAssertEqual(h["HTTP/1.1 200"], .statusLine)
        XCTAssertEqual(h["Content-Type"], .headerName)
        XCTAssertEqual(h[" application/json"], .headerValue)
        XCTAssertEqual(h[#""a""#], .key)

        let js = tokens("var x = 0x1b; // note\nreturn 'hi';", .javascript)
        XCTAssertEqual(js["var"], .storage)
        XCTAssertEqual(js["return"], .keyword)
        XCTAssertEqual(js["0x1b"], .number)
        XCTAssertEqual(js["// note"], .comment)
        XCTAssertEqual(js["'hi'"], .string)
    }

    func testJavaScriptFunctionsAndBrackets() {
        let code = "function xt(a) { if (a) { return f(\"(\"); } } // )"
        let spans = Syntax.spans(code, kind: .javascript)
        let ns = code as NSString
        func token(_ text: String) -> Token? {
            let r = ns.range(of: text)
            return spans.last { NSIntersectionRange($0.0, r).length == r.length && $0.0.length >= r.length }?.1
        }
        XCTAssertEqual(token("function"), .storage)
        XCTAssertEqual(token("xt"), .function)
        XCTAssertEqual(token("if"), .keyword)
        XCTAssertEqual(token("// )"), .comment)
        let depths = spans.compactMap { r, t -> String? in
            guard case .bracket(let d) = t else { return nil }
            return ns.substring(with: r) + "\(d)"
        }
        // The "(" inside the string and the ")" in the comment are not counted.
        XCTAssertEqual(depths, ["(0", ")0", "{0", "(1", ")1", "{1", "(2", ")2", "}1", "}0"])
    }

    func testThemeIsWrittenOnFirstUseAndReadBack() throws {
        let file = Theme.file
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(Theme.current, Theme.default)
        XCTAssertEqual(try JSONDecoder().decode(Theme.self, from: Data(contentsOf: file)), Theme.default,
                       "first use writes theme.json so it can be edited")

        // Edits are picked up on the next read.
        var custom = Theme.default
        custom.dark.key = "#123456"
        try enc.encode(custom).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        XCTAssertEqual(Theme.current.dark.key, "#123456")

        // A file that doesn't decode falls back to the default palette instead of breaking highlighting.
        try Data(##"{"light":{"key":"#000000"}}"##.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)
        XCTAssertEqual(Theme.current, Theme.default)
    }
}
