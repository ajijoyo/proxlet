//
//  ScriptMeta.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
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

    public init() {}

    /// Rewrites only the `@enabled` header of a script file.
    public static func setEnabled(_ enabled: Bool, file: URL) throws {
        let (meta, code) = parse(try String(contentsOf: file, encoding: .utf8))
        var updated = meta
        updated.enabled = enabled
        try updated.render(code: code).write(to: file, atomically: true, encoding: .utf8)
    }

    public func matches(method: String, url: String) -> Bool {
        guard enabled else { return false }
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
            switch key {
            case "name": meta.name = value
            case "enabled": meta.enabled = value != "false"
            case "match": meta.match = value
            case "regex": meta.useRegex = value == "true"
            case "method": meta.method = value.isEmpty || value.uppercased() == "ANY" ? nil : value.uppercased()
            case "request": meta.onRequest = value != "false"
            case "response": meta.onResponse = value != "false"
            default: break
            }
        }
        return (meta, lines.joined(separator: "\n"))
    }

    /// Source with the metadata header followed by `code`.
    public func render(code: String) -> String {
        [
            "// @name \(name)",
            "// @enabled \(enabled)",
            "// @match \(match)",
            "// @regex \(useRegex)",
            "// @method \(method ?? "ANY")",
            "// @request \(onRequest)",
            "// @response \(onResponse)",
        ].joined(separator: "\n") + "\n" + code
    }
}
