//
//  MapLocalArchive.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Map Local rules as one portable .json file; also reads a `MapLocalFiles-RuleTree` export.
public enum MapLocalArchive {
    struct Envelope: Codable {
        var format = "proxlet-map-local"
        var version = 1
        var rules: [MockRule]
    }

    public struct FormatError: LocalizedError {
        public var errorDescription: String? {
            "This file has no Map Local rules Proxlet can read."
        }
    }

    /// Text bodies read from `bodyFile` are inlined so the export works on another Mac; binary ones keep the path.
    public static func export(_ rules: [MockRule]) throws -> Data {
        let portable = rules.map { rule -> MockRule in
            var r = rule
            if let path = r.bodyFile, let data = FileManager.default.contents(atPath: path),
               let text = String(data: data, encoding: .utf8) {
                r.body = text
                r.bodyFile = nil
            }
            return r
        }
        return try RuleStore.encoder.encode(Envelope(rules: portable))
    }

    /// Rules from a Proxlet export, a bare rule array, or a rule tree export; every rule gets a fresh id and date.
    public static func importRules(_ data: Data) throws -> [MockRule] {
        let decoder = RuleStore.decoder
        var rules: [MockRule]
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            rules = envelope.rules
        } else if let array = try? decoder.decode([MockRule].self, from: data) {
            rules = array
        } else if let proxyman = try Proxyman.mapLocalRules(data) {
            rules = proxyman
        } else {
            throw FormatError()
        }
        for i in rules.indices {
            rules[i].id = UUID().uuidString.lowercased()
            rules[i].createdAt = Date()
        }
        return rules
    }
}
