//
//  ScriptStore.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// `scripts/*.js` as the app and proxlet-mcp see it. A script's id is its file name without `.js`.
public enum ScriptStore {
    public struct Script: Equatable, Sendable {
        public let fileName: String
        public let meta: ScriptMeta
        public var id: String { String(fileName.dropLast(3)) }
    }

    public struct InvalidID: LocalizedError {
        public let id: String
        public var errorDescription: String? { "No script \"\(id)\" in \(Paths.scripts.path)" }
    }

    public static func fileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: Paths.scripts.path)) ?? []).filter { $0.hasSuffix(".js") }.sorted()
    }

    public static func list() -> [Script] {
        fileNames().map { name in
            let source = (try? String(contentsOf: Paths.scripts.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return Script(fileName: name, meta: ScriptMeta.parse(source).0)
        }
    }

    /// File for an existing script id, kept verbatim (hand-named files like `my.script.js` work); never escapes `scripts/`.
    public static func url(forID id: String) throws -> URL {
        let name = id.hasSuffix(".js") ? id : id + ".js"
        guard !name.contains("/"), !name.hasPrefix("."), fileNames().contains(name) else { throw InvalidID(id: id) }
        return Paths.scripts.appendingPathComponent(name)
    }

    /// Moves the script to the Trash, so it can be restored (same for the app and MCP).
    public static func delete(fileName: String) throws {
        try FileManager.default.trashItem(at: Paths.scripts.appendingPathComponent(fileName), resultingItemURL: nil)
    }

    /// Writes a new script and returns its file name.
    @discardableResult
    public static func create(fileName: String, meta: ScriptMeta, code: String) throws -> String {
        try Paths.ensure()
        try meta.render(code: code).write(to: Paths.scripts.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        return fileName
    }

    /// File for "Add Script" on a URL: the existing script scoped to exactly this URL, otherwise a new unique name.
    /// The slug is lossy (`a-b` and `a/b` collide), so an existing file is reused only when its `@match` agrees.
    public static func fileName(forURL base: String, method: String?) -> (fileName: String, exists: Bool) {
        let slug = base.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let preferred = "\(slug.prefix(80)).js"
        if let existing = list().first(where: { $0.fileName == preferred }),
           existing.meta.match == base + "*", existing.meta.method == method {
            return (preferred, true)
        }
        var used = Set(fileNames())
        return (uniqueFileName(for: String(slug.prefix(80)), used: &used), false)
    }

    public static func uniqueFileName(for name: String, used: inout Set<String>) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let base = slug.isEmpty ? "script" : String(slug.prefix(60))
        var candidate = "\(base).js"
        var n = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(n).js"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }
}
