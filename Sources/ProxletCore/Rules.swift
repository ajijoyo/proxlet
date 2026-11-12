//
//  Rules.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import UniformTypeIdentifiers

/// Map Local rule: a request matching `urlPattern` gets this response without hitting the network.
public struct MockRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var method: String?
    /// Full URL with `*` wildcards (e.g. `https://api.example.com/users/*`), or a regex when `useRegex`.
    public var urlPattern: String
    public var useRegex: Bool
    public var status: Int
    public var headers: [String: String]
    public var body: String
    /// Absolute path whose contents replace `body` when set.
    public var bodyFile: String?
    /// Milliseconds to wait before answering; nil answers immediately.
    public var delayMs: Int?
    /// When the rule was created; nil for rules saved before this was recorded.
    public var createdAt: Date?
    /// File the rule was loaded from (not persisted); rule files may be named by hand, not only `<id>.json`.
    public var sourceFile: URL?

    /// Longest delay a rule may hold a request for.
    public static let maxDelayMs = 60_000

    /// Methods offered by the editors and the MCP tools.
    public static let methods = ["ANY", "GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, method, urlPattern, useRegex, status, headers, body, bodyFile, delayMs, createdAt
    }

    public init(
        id: String = UUID().uuidString.lowercased(), name: String = "", enabled: Bool = true, method: String? = nil,
        urlPattern: String, useRegex: Bool = false, status: Int = 200, headers: [String: String] = [:],
        body: String = "", bodyFile: String? = nil, delayMs: Int? = nil, createdAt: Date? = Date()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.method = method
        self.urlPattern = urlPattern
        self.useRegex = useRegex
        self.status = status
        self.headers = headers
        self.body = body
        self.bodyFile = bodyFile
        self.delayMs = delayMs
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        useRegex = try c.decodeIfPresent(Bool.self, forKey: .useRegex) ?? false
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        method = try c.decodeIfPresent(String.self, forKey: .method)
        urlPattern = try c.decode(String.self, forKey: .urlPattern)
        status = try c.decodeIfPresent(Int.self, forKey: .status) ?? 200
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        bodyFile = try c.decodeIfPresent(String.self, forKey: .bodyFile)
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// Rule replaying a captured flow's response for the same method + URL.
    /// Check `flow.hasPartialResponseBody` first: binary or truncated bodies are stored as placeholder text.
    public init(flow: Flow, urlPattern: String? = nil, status: Int? = nil, body: String? = nil) {
        // The stored body is already decoded and re-serialized, so length/encoding headers no longer apply.
        let skip: Set<String> = ["content-length", "content-encoding", "transfer-encoding"]
        var headers: [String: String] = [:]
        for h in flow.responseHeaders where !skip.contains(h.name.lowercased()) { headers[h.name] = h.value }
        self.init(name: "\(flow.method) \(flow.host)\(flow.path)", method: flow.method, urlPattern: urlPattern ?? flow.url,
                  status: status ?? flow.status,
                  headers: headers, body: body ?? flow.responseBody)
    }

    /// Rule from a captured flow. A binary body recorded in `bodies/` is copied to `map-local-files/`;
    /// nil when only a placeholder was recorded.
    public static func from(flow: Flow, urlPattern: String? = nil) throws -> MockRule? {
        var rule = MockRule(flow: flow, urlPattern: urlPattern)
        guard flow.hasPartialResponseBody else { return rule }
        guard let data = BodyStore.load(flowID: flow.id) else { return nil }
        let type = rule.headers.first { $0.key.lowercased() == "content-type" }?.value.components(separatedBy: ";")[0]
        let ext = type.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "bin"
        try FileManager.default.createDirectory(at: Paths.mapLocalFiles, withIntermediateDirectories: true)
        let file = Paths.mapLocalFiles.appendingPathComponent("\(rule.id).\(ext)")
        try data.write(to: file, options: .atomic)
        rule.body = ""
        rule.bodyFile = file.path
        return rule
    }

    public func matches(method: String, url: String) -> Bool {
        guard enabled else { return false }
        if let m = self.method, !m.isEmpty, m.uppercased() != method.uppercased() { return false }
        return Self.url(url, matches: urlPattern, regex: useRegex)
    }

    /// Glob (`*`) or regex URL match; an invalid regex matches nothing.
    public static func url(_ url: String, matches pattern: String, regex: Bool) -> Bool {
        regex ? url.range(of: pattern, options: .regularExpression) != nil : glob(pattern, matches: url)
    }

    public static func glob(_ pattern: String, matches text: String) -> Bool {
        let regex = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return text.range(of: regex, options: .regularExpression) != nil
    }

    public func response() -> ProxyResponse {
        let data = bodyFile.flatMap { FileManager.default.contents(atPath: $0) } ?? Data(body.utf8)
        var hdrs = headers.map { Header(name: $0.key, value: $0.value) }
        if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
            // A body file is typed by its extension, e.g. a .png mock is served as image/png.
            let fileType = bodyFile.map { UTType(filenameExtension: ($0 as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream" }
            hdrs.append(Header(name: "Content-Type", value: fileType ?? "application/json"))
        }
        hdrs.append(Header(name: "X-Proxlet-Mock", value: id))
        // Not cacheable, so turning the rule or Map Local off is visible on the next request.
        return ProxyResponse(status: status, headers: FlowPipeline.noStore(hdrs), body: data)
    }
}

/// Rules live as one JSON file each in `rules/`, so agents and the UI can edit them directly.
public enum RuleStore {
    /// Re-read on every request so file edits apply immediately.
    public static func load() -> [MockRule] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.rules, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), var rule = try? decoder.decode(MockRule.self, from: data)
                else { return nil }
                rule.sourceFile = url
                return rule
            }
    }

    public static func match(method: String, url: String) -> MockRule? {
        load().first { $0.matches(method: method, url: url) }
    }

    /// Pretty, stable JSON shared by rule files and Map Local exports.
    static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    /// Writes back to the file the rule came from, or `<id>.json` for new rules.
    public static func save(_ rule: MockRule) throws {
        try Paths.ensure()
        try encoder.encode(rule).write(to: file(for: rule), options: .atomic)
    }

    /// Also deletes the rule's body file when Proxlet owns it; a user's own file is left alone.
    public static func delete(_ rule: MockRule) throws {
        try FileManager.default.removeItem(at: file(for: rule))
        if let body = rule.bodyFile, isOwned(body) { try? FileManager.default.removeItem(atPath: body) }
    }

    /// True for body files Proxlet copied into `map-local-files/`; only those are ever deleted.
    public static func isOwned(_ bodyFile: String) -> Bool {
        URL(fileURLWithPath: bodyFile).deletingLastPathComponent().standardizedFileURL == Paths.mapLocalFiles.standardizedFileURL
    }

    /// Exact file backing a rule.
    public static func file(for rule: MockRule) -> URL { rule.sourceFile ?? file(rule.id) }

    /// Default file for a new rule id.
    public static func file(_ id: String) -> URL {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return Paths.rules.appendingPathComponent("\(safe).json")
    }
}
