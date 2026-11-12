//
//  FlowQuery.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Pure helpers behind the MCP tools (`filter_flows`, `export_flow_curl`, `include_paths`, `export_flows`).
public enum FlowQuery {
    public static let keys = ["url", "queryString", "host", "method", "statusCode", "requestHeader", "responseHeader", "requestBody",
                              "responseBody", "device"]
    public static let matchings = ["contains", "notContains", "startWith", "endWith", "equal", "notEqual", "regex", "wildcard"]

    public struct Filter: Equatable, Sendable {
        public var key: String
        public var matching: String
        public var value: String
        public var caseSensitive: Bool

        public init(key: String, matching: String = "contains", value: String, caseSensitive: Bool = false) {
            self.key = key
            self.matching = matching
            self.value = value
            self.caseSensitive = caseSensitive
        }
    }

    public struct UnknownValue: LocalizedError {
        public let field: String
        public let value: String
        public var errorDescription: String? { "Unknown \(field) \"\(value)\"" }
    }

    /// Rejects keys/matchings that would otherwise silently fall back to a default.
    public static func validate(_ filter: Filter) throws {
        guard keys.contains(filter.key) else { throw UnknownValue(field: "key", value: filter.key) }
        guard matchings.contains(filter.matching) else { throw UnknownValue(field: "matching", value: filter.matching) }
    }

    public static func isValidRegex(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    public static func matches(_ flow: Flow, _ filter: Filter) -> Bool {
        let field = value(of: filter.key, in: flow)
        if filter.matching == "regex" {
            let options: String.CompareOptions = filter.caseSensitive ? [.regularExpression] : [.regularExpression, .caseInsensitive]
            return field.range(of: filter.value, options: options) != nil
        }
        let a = filter.caseSensitive ? field : field.lowercased()
        let b = filter.caseSensitive ? filter.value : filter.value.lowercased()
        switch filter.matching {
        case "notContains": return !a.contains(b)
        case "startWith": return a.hasPrefix(b)
        case "endWith": return a.hasSuffix(b)
        case "equal": return a == b
        case "notEqual": return a != b
        case "wildcard": return MockRule.glob(b, matches: a)
        default: return a.contains(b)
        }
    }

    /// Text a filter key refers to (headers as `Name: value` lines).
    static func value(of key: String, in flow: Flow) -> String {
        switch key {
        case "url": flow.url
        case "queryString": URLComponents(string: flow.url)?.percentEncodedQuery ?? ""
        case "host": flow.host
        case "method": flow.method
        case "statusCode": String(flow.status)
        case "requestHeader": headerText(flow.requestHeaders)
        case "responseHeader": headerText(flow.responseHeaders)
        case "requestBody": flow.requestBody
        case "device": flow.device ?? ""
        default: flow.responseBody
        }
    }

    /// `and` requires every filter to match, `or` any of them.
    public static func matches(_ flow: Flow, _ filters: [Filter], any: Bool) -> Bool {
        any ? filters.contains { matches(flow, $0) } : filters.allSatisfy { matches(flow, $0) }
    }

    static func headerText(_ headers: [Header]) -> String {
        headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
    }

    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func curl(_ f: Flow) -> String {
        var parts = ["curl", "-X", f.method, shellQuote(f.url)]
        for h in f.requestHeaders where h.name.lowercased() != "content-length" {
            parts += ["-H", shellQuote("\(h.name): \(h.value)")]
        }
        if !f.requestBody.isEmpty { parts += ["--data-raw", shellQuote(f.requestBody)] }
        return parts.joined(separator: " ")
    }

    /// `include_paths`: true appends `*`, false removes one trailing `*`, nil keeps the pattern.
    public static func withSubpaths(_ url: String, _ include: Bool?) -> String {
        switch include {
        case true?: url.hasSuffix("*") ? url : url + "*"
        case false?: url.hasSuffix("*") ? String(url.dropLast()) : url
        case nil: url
        }
    }

    /// Export destination: a directory gets a generated file name; a file gets the right extension.
    public static func exportURL(path: String, format: String, now: Date = Date()) -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.appendingPathComponent("Proxlet Session \(Int(now.timeIntervalSince1970)).\(format)")
        }
        return url.pathExtension.lowercased() == format ? url : url.appendingPathExtension(format)
    }
}
