//
//  SSLProxying.swift
//  ProxletCore
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// HTTPS hosts Proxlet decrypts; every other CONNECT is relayed untouched.
public struct SSLProxying: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Hashable, Sendable {
        public var domain: String
        public var enabled = true

        public init(domain: String, enabled: Bool = true) {
            self.domain = domain
            self.enabled = enabled
        }
    }

    public enum List: String, CaseIterable, Sendable {
        case include, exclude
    }

    public var include: [Entry] = []
    public var exclude: [Entry] = []

    public init() {}

    /// Decrypted when an enabled include entry matches and no enabled exclude entry does.
    public func shouldDecrypt(_ host: String) -> Bool {
        let host = host.lowercased()
        func hit(_ entries: [Entry]) -> Bool { entries.contains { $0.enabled && MockRule.glob($0.domain, matches: host) } }
        return hit(include) && !hit(exclude)
    }

    public func entries(_ list: List) -> [Entry] { list == .include ? include : exclude }

    /// Host or `*.host` pattern from user input, e.g. a pasted URL; nil when it isn't one.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespaces).lowercased()
        if text.contains("://") { text = URLComponents(string: text)?.host ?? "" }
        if let colon = text.lastIndex(of: ":"), !text.contains("::"), text[text.index(after: colon)...].allSatisfy(\.isNumber) {
            text = String(text[..<colon])
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-*")
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return text
    }

    /// Adds (or re-enables) a domain; false when the input isn't a host.
    @discardableResult
    public mutating func add(_ input: String, to list: List = .include) -> Bool {
        guard let domain = Self.normalize(input) else { return false }
        if !setEnabled(true, domain: domain, list: list) { modify(list) { $0.append(Entry(domain: domain)) } }
        return true
    }

    @discardableResult
    public mutating func remove(_ input: String, from list: List = .include) -> Bool {
        let domain = Self.normalize(input) ?? input
        guard entries(list).contains(where: { $0.domain == domain }) else { return false }
        modify(list) { $0.removeAll { $0.domain == domain } }
        return true
    }

    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, domain input: String, list: List = .include) -> Bool {
        let domain = Self.normalize(input) ?? input
        guard let i = entries(list).firstIndex(where: { $0.domain == domain }) else { return false }
        modify(list) { $0[i].enabled = enabled }
        return true
    }

    /// Turns off every enabled include entry that decrypts `host` (the host itself or a matching `*.` pattern).
    public mutating func disableIncludes(matching host: String) {
        let host = host.lowercased()
        for i in include.indices where include[i].enabled && MockRule.glob(include[i].domain, matches: host) {
            include[i].enabled = false
        }
    }

    private mutating func modify(_ list: List, _ change: (inout [Entry]) -> Void) {
        if list == .include { change(&include) } else { change(&exclude) }
    }

    // MARK: - ssl-proxying.json, shared with proxlet-mcp

    private static let lock = NSLock()
    private struct Cached {
        let path: String
        let modified: Date
        let value: SSLProxying
    }

    nonisolated(unsafe) private static var cache: Cached?

    /// Read on every CONNECT, so cached by modification date.
    public static func load() -> SSLProxying {
        lock.withLock {
            let path = Paths.sslProxying.path
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            guard let modified else { return SSLProxying() }
            if let cache, cache.path == path, cache.modified == modified { return cache.value }
            let value = (try? JSONDecoder().decode(SSLProxying.self, from: Data(contentsOf: Paths.sslProxying))) ?? SSLProxying()
            cache = Cached(path: path, modified: modified, value: value)
            return value
        }
    }

    @discardableResult
    public static func update(_ change: (inout SSLProxying) -> Void) throws -> SSLProxying {
        var value = load()
        change(&value)
        try Paths.ensure()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(value).write(to: Paths.sslProxying, options: .atomic)
        lock.withLock { cache = nil }
        return value
    }
}
