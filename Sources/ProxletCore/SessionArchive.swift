//
//  SessionArchive.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Session export/import as HAR 1.2, plus Charles `.chls` via Charles' own converter
/// (`.chls` is Java-serialized).
public enum SessionArchive {
    public struct Imported {
        public var flow: Flow
        public var messages: [WebSocketMessage]
    }

    // MARK: - Files

    public static func export(_ flows: [Flow], to url: URL) throws {
        let har = try encodeHAR(flows)
        guard url.pathExtension.lowercased() == "chls" else {
            try har.write(to: url, options: .atomic)
            return
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("proxlet-\(UUID().uuidString).har")
        defer { try? FileManager.default.removeItem(at: temp) }
        try har.write(to: temp)
        try CharlesConverter.convert(temp, to: url)
    }

    public static func importFile(_ url: URL) throws -> [Imported] {
        guard url.pathExtension.lowercased() == "chls" else { return try decodeHAR(Data(contentsOf: url)) }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("proxlet-\(UUID().uuidString).har")
        defer { try? FileManager.default.removeItem(at: temp) }
        try CharlesConverter.convert(url, to: temp)
        return try decodeHAR(Data(contentsOf: temp))
    }

    // MARK: - HAR 1.2

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func headers(_ list: [Header]) -> [[String: String]] { list.map { ["name": $0.name, "value": $0.value] } }

    static func mimeType(_ list: [Header]) -> String {
        list.first { $0.name.lowercased() == "content-type" }?.value ?? ""
    }

    public static func encodeHAR(_ flows: [Flow]) throws -> Data {
        let entries: [[String: Any]] = flows.map { f in
            let query = URLComponents(string: f.url)?.queryItems?.map { ["name": $0.name, "value": $0.value ?? ""] } ?? []
            var request: [String: Any] = [
                "method": f.method, "url": f.url, "httpVersion": "HTTP/1.1", "headers": headers(f.requestHeaders),
                "queryString": query, "cookies": [], "headersSize": -1, "bodySize": f.requestBody.utf8.count,
            ]
            if !f.requestBody.isEmpty { request["postData"] = ["mimeType": mimeType(f.requestHeaders), "text": f.requestBody] }
            var entry: [String: Any] = [
                "startedDateTime": iso.string(from: f.startedAt),
                "time": f.durationMs,
                "request": request,
                "response": [
                    "status": f.status, "statusText": HTTPReason.phrase(f.status),
                    "httpVersion": "HTTP/1.1", "headers": headers(f.responseHeaders), "cookies": [],
                    "content": ["size": f.responseBody.utf8.count, "mimeType": mimeType(f.responseHeaders), "text": f.responseBody],
                    "redirectURL": "", "headersSize": -1, "bodySize": f.responseBody.utf8.count,
                ],
                "cache": [:],
                "timings": ["send": 0, "wait": f.durationMs, "receive": 0],
            ]
            if f.websocket {
                entry["_resourceType"] = "websocket"
                entry["_webSocketMessages"] = WebSocketStore.load(flowID: f.id).map { m in
                    ["type": m.direction, "time": m.time.timeIntervalSince1970, "opcode": m.type == "binary" ? 2 : 1, "data": m.text]
                }
            }
            return entry
        }
        let log: [String: Any] = ["log": ["version": "1.2", "creator": ["name": "Proxlet", "version": Paths.appVersion], "entries": entries]]
        return try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    public struct FormatError: LocalizedError {
        public var errorDescription: String? { "Not a HAR 1.2 file (missing log.entries)." }
    }

    public static func decodeHAR(_ data: Data) throws -> [Imported] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = root["log"] as? [String: Any], let entries = log["entries"] as? [[String: Any]] else {
            throw FormatError()
        }
        return entries.compactMap { e in
            guard let req = e["request"] as? [String: Any], let method = req["method"] as? String,
                  let url = req["url"] as? String else { return nil }
            let res = e["response"] as? [String: Any] ?? [:]
            func hdrs(_ any: Any?) -> [Header] {
                (any as? [[String: Any]] ?? []).compactMap { h in
                    guard let n = h["name"] as? String else { return nil }
                    return Header(name: n, value: h["value"] as? String ?? "")
                }
            }
            let content = res["content"] as? [String: Any] ?? [:]
            var responseBody = content["text"] as? String ?? ""
            if (content["encoding"] as? String)?.lowercased() == "base64", let raw = Data(base64Encoded: responseBody) {
                responseBody = Flow.text(raw)
            }
            let requestBody = (req["postData"] as? [String: Any])?["text"] as? String ?? ""
            let started = (e["startedDateTime"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? Date()
            let wsMessages = (e["_webSocketMessages"] as? [[String: Any]] ?? []).map { m -> WebSocketMessage in
                let text = m["data"] as? String ?? ""
                return WebSocketMessage(time: Date(timeIntervalSince1970: m["time"] as? Double ?? 0),
                                        direction: m["type"] as? String == "send" ? "send" : "receive",
                                        type: (m["opcode"] as? Int) == 2 ? "binary" : "text",
                                        size: text.utf8.count, text: text)
            }
            let isWebSocket = e["_resourceType"] as? String == "websocket" || !wsMessages.isEmpty
            let flow = Flow(startedAt: started, method: method, url: url, requestHeaders: hdrs(req["headers"]),
                            requestBody: requestBody, status: res["status"] as? Int ?? 0, responseHeaders: hdrs(res["headers"]),
                            responseBody: responseBody, durationMs: Int((e["time"] as? Double) ?? 0), websocket: isWebSocket)
            return Imported(flow: flow, messages: wsMessages)
        }
    }
}

/// Wraps `Charles convert <in> <out>`, which converts between Charles sessions and HAR by file extension.
public enum CharlesConverter {
    public struct Missing: LocalizedError {
        public var errorDescription: String? {
            "Charles Proxy is needed to read or write .chls files (it is Charles' own binary format). "
                + "Install Charles, or use .har, which Proxyman and Charles both open."
        }
    }

    public static var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/Charles.app/Contents/MacOS/Charles", "\(home)/Applications/Charles.app/Contents/MacOS/Charles"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func convert(_ input: URL, to output: URL) throws {
        guard let charles = executable else { throw Missing() }
        try SystemProxy.run(charles, ["convert", input.path, output.path])
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw SystemProxy.CommandError(output: "Charles did not produce \(output.lastPathComponent).")
        }
    }
}
