//
//  ScriptMeta.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the GNU General Public License v3.0.
//

import Foundation

/// Matching rules stored as `// @key value` comment lines at the top of a script.
/// A script without `@match` runs on every request.
public struct ScriptMeta: Equatable, Sendable {
    public var name = ""
    public var enabled = true
    public var match = ""
    public var useRegex = false
    /// nil means any method.
    public var method: String?
    public var onRequest = true
    public var onResponse = true
    public var devices: [String]?
    public var isDeviceSpecific: Bool { !(devices ?? []).isEmpty }
    /// `@created`; nil for scripts written before this was recorded.
    public var created: Date?

    public init() {}

    /// Rewrites only the `@enabled` header of a script file.
    public static func setEnabled(_ enabled: Bool, file: URL) throws {
        let (meta, code) = parse(try String(contentsOf: file, encoding: .utf8))
        var updated = meta
        updated.enabled = enabled
        try updated.render(code: code).write(to: file, atomically: true, encoding: .utf8)
    }

    public func matches(method: String, url: String, device: String? = nil) -> Bool {
        guard enabled else { return false }
        if isDeviceSpecific {
            guard let device, devices?.contains(where: { $0.caseInsensitiveCompare(device) == .orderedSame }) == true else { return false }
        }
        if let m = self.method, m.uppercased() != method.uppercased() { return false }
        return match.isEmpty || MockRule.url(url, matches: match, regex: useRegex)
    }

    /// Parses the leading comment block; returns the metadata and the code after it.
    public static func parse(_ source: String) -> (ScriptMeta, code: String) {
        var meta = ScriptMeta()
        var lines = source.components(separatedBy: "\n")[...]
        while let line = lines.first?.trimmingCharacters(in: .whitespaces), line.hasPrefix("// @") {
            lines = lines.dropFirst()
            let body = line.dropFirst(4)
            let key = body.prefix { !$0.isWhitespace }
            let value = body.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            meta.set(key, value)
        }
        return (meta, lines.joined(separator: "\n"))
    }

    private mutating func set(_ key: Substring, _ value: String) {
        switch key {
        case "name": name = value
        case "enabled": enabled = value != "false"
        case "match": match = value
        case "regex": useRegex = value == "true"
        case "method": method = value.isEmpty || value.uppercased() == "ANY" ? nil : value.uppercased()
        case "request": onRequest = value != "false"
        case "response": onResponse = value != "false"
        case "devices": devices = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "created": created = ISO8601DateFormatter().date(from: value)
        default: break
        }
    }

    /// Source with the metadata header followed by `code`.
    public func render(code: String) -> String {
        ([
            "// @name \(name)",
            "// @enabled \(enabled)",
            "// @match \(match)",
            "// @regex \(useRegex)",
            "// @method \(method ?? "ANY")",
            "// @request \(onRequest)",
            "// @response \(onResponse)",
        ]
            + (isDeviceSpecific ? ["// @devices \((devices ?? []).joined(separator: ","))"] : [])
            + (created.map { ["// @created \(ISO8601DateFormatter().string(from: $0))"] } ?? [])
        ).joined(separator: "\n") + "\n" + code
    }
}
