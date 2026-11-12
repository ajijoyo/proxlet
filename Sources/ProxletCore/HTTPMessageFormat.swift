//
//  HTTPMessageFormat.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Map Local file format: status line, headers, blank line, body (e.g. `<host>_<ID>.json`).
public enum HTTPMessageFormat {
    public struct Message: Equatable, Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: String
    }

    public static func parse(_ text: String) -> Message? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        let head = parts[0].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let statusLine = head[0].split(separator: " ")
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/"), let status = Int(statusLine[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return Message(status: status, headers: headers, body: parts.dropFirst().joined(separator: "\n\n"))
    }

    /// An HTTP message, or else a plain file used as a 200 body typed by its extension.
    public static func parseFile(_ text: String, pathExtension: String) -> Message {
        if let message = parse(text) { return message }
        let types = ["json": "application/json", "html": "text/html", "xml": "application/xml", "svg": "image/svg+xml",
                     "js": "application/javascript", "css": "text/css"]
        return Message(status: 200, headers: ["Content-Type": types[pathExtension.lowercased()] ?? "text/plain"], body: text)
    }

    public static func render(status: Int, headers: [String: String], body: String) -> String {
        render(status: status, headers: headers.sorted { $0.key < $1.key }.map { Header(name: $0.key, value: $0.value) }, body: body)
    }

    public static func render(status: Int, headers: [Header], body: String) -> String {
        let lines = ["HTTP/1.1 \(status) \(HTTPReason.phrase(status))"] + headers.map { "\($0.name): \($0.value)" }
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    /// A flow's response as a Map Local file; length/encoding headers are dropped since the body is re-serialized.
    public static func render(response flow: Flow) -> String {
        let skip: Set<String> = ["content-length", "transfer-encoding", "content-encoding"]
        return render(status: flow.status, headers: flow.responseHeaders.filter { !skip.contains($0.name.lowercased()) },
                      body: JSONFormatter.pretty(flow.responseBody) ?? flow.responseBody)
    }

    /// Exported responses are named `<host>_<ID>.json`; `rule(fromFile:)` reads the host back.
    public static func fileName(host: String, id: String) -> String {
        "\(host.isEmpty ? "response" : host)_\(id.prefix(8).uppercased()).json"
    }

    public static func fileName(for flow: Flow) -> String { fileName(host: flow.host, id: flow.id) }

    /// Map Local rule from a file; the URL is guessed from a `<host>_<ID>` file name.
    public static func rule(fromFile url: URL) -> MockRule? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let msg = parseFile(text, pathExtension: url.pathExtension)
        let stem = url.deletingPathExtension().lastPathComponent
        let host = stem.split(separator: "_").first.map(String.init) ?? ""
        let pattern = host.contains(".") ? "https://\(host)/*" : "https://example.com/*"
        return MockRule(name: stem, urlPattern: pattern, status: msg.status, headers: msg.headers, body: msg.body)
    }

    /// Pretty-prints the body when it is JSON; leaves everything else as-is.
    public static func beautify(_ text: String) -> String {
        guard let msg = parse(text), let pretty = JSONFormatter.pretty(msg.body) else { return text }
        return render(status: msg.status, headers: msg.headers, body: pretty)
    }
}
