//
//  ImportTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import ProxletCore
import XCTest

/// Rule exports from other tools: embedded bodies, and each import dialog refusing the other kind of file.
final class ImportTests: XCTestCase {
    func testImportRuleExportWithEmbeddedBodies() throws {
        let message = "HTTP/1.1 202 Accepted\nContent-Type: application/json\n\n{\"data\":\"x\"}"
        let node: [String: Any] = ["nodeType": ["node": ["_0": [
            "id": "A1", "name": "room meta", "url": "https://api.acme.test/api/v2/feeds/meta/1001*", "regex": "useWildcard",
            "method": ["exact": [["name": "GET"]]], "isEnabled": false, "isLocalFileEnable": true,
            "localFile": ["path": "/nonexistent/map-local/A1.txt", "name": "room meta",
                          "importFileData": Data(message.utf8).base64EncodedString()]]]]]
        let export = try JSONSerialization.data(withJSONObject: [node])
        for data in [export, try XCTUnwrap(ContentDecoding.gzip(export))] {
            let rules = try MapLocalArchive.importRules(data)
            XCTAssertEqual(rules.count, 1, "a bare node array, plain or gzipped")
            XCTAssertEqual(rules[0].urlPattern, "https://api.acme.test/api/v2/feeds/meta/1001*")
            XCTAssertEqual(rules[0].method, "GET")
            XCTAssertFalse(rules[0].enabled)
            XCTAssertEqual(rules[0].status, 202, "the body comes from importFileData, not the missing path")
            XCTAssertEqual(rules[0].headers["Content-Type"], "application/json")
            XCTAssertEqual(rules[0].body, #"{"data":"x"}"#)
        }
    }

    func testEachImporterRejectsTheOtherKindOfExport() throws {
        let script: [String: Any] = ["nodeType": ["node": ["_0": ["name": "s", "url": "*", "fileContent": "function onResponse(a,b,c,d){return d;}",
                                                                   "isEnableRequest": false, "isEnableResponse": true]]]]
        let scripting = try XCTUnwrap(ContentDecoding.gzip(JSONSerialization.data(withJSONObject: ["tree": [script], "userFiles": []])))
        XCTAssertThrowsError(try MapLocalArchive.importRules(scripting)) {
            XCTAssertEqual($0.localizedDescription, "This file has scripts, not Map Local rules. Import it from the Scripts page.")
        }

        let mapLocal: [String: Any] = ["nodeType": ["node": ["_0": ["name": "m", "url": "https://api.acme.test/*", "isLocalFileEnable": true,
                                                                    "localFile": ["path": "/nonexistent/m.txt"]]]]]
        for export in [try JSONSerialization.data(withJSONObject: [mapLocal]),
                       try JSONSerialization.data(withJSONObject: ["nodes": [mapLocal]]),
                       try JSONSerialization.data(withJSONObject: ["tree": [mapLocal]])] {
            XCTAssertThrowsError(try Proxyman.ScriptConfig.importConfig(export)) {
                XCTAssertEqual($0.localizedDescription, "This file has Map Local rules, not scripts. Import it from the Map Local page.")
            }
        }
        XCTAssertEqual(try MapLocalArchive.importRules(JSONSerialization.data(withJSONObject: [mapLocal])).count, 1, "still imports on its own page")
    }
}
