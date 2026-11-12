//
//  Flow.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import NIOHTTP1

public struct Header: Codable, Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct ProxyRequest: Codable, Sendable {
    public var method: String
    public var url: String
    public var headers: [Header]
    public var body: Data
    /// Local app that opened the connection, when it came from this Mac.
    public var clientApp: String?
    /// iOS simulator UDID when the client app runs in a simulator.
    public var clientDevice: String?

    public init(method: String, url: String, headers: [Header], body: Data, clientApp: String? = nil, clientDevice: String? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.clientApp = clientApp
        self.clientDevice = clientDevice
    }
}

public struct ProxyResponse: Codable, Sendable {
    public var status: Int
    public var headers: [Header]
    public var body: Data

    public init(status: Int, headers: [Header], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// One completed request/response pair, as stored in flows.jsonl.
public struct Flow: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var startedAt: Date
    public var method: String
    public var url: String
    public var requestHeaders: [Header]
    public var requestBody: String
    public var status: Int
    public var responseHeaders: [Header]
    public var responseBody: String
    public var durationMs: Int
    public var mocked: Bool
    public var error: String?
    /// Script files that changed this flow, e.g. ["decrypt.js"].
    public var scripts: [String]
    /// WebSocket handshake; messages live in WebSocketStore.
    public var websocket: Bool

    /// URL parts parsed once (not persisted); the UI reads them for every flow on each render.
    public private(set) var host = ""
    /// Path plus query string.
    public private(set) var path = ""
    /// Path without query string, "/" when empty.
    public private(set) var pathOnly = "/"
    public private(set) var pathSegments: [String] = []
    /// Client app: the local process's .app when known, else guessed from User-Agent.
    public private(set) var app = "Unknown"
    /// iOS simulator UDID of the client, when known.
    public private(set) var device: String?

    enum CodingKeys: String, CodingKey {
        case id, startedAt, method, url, requestHeaders, requestBody, status, responseHeaders, responseBody
        case durationMs, mocked, error, scripts, app, websocket, device
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        method = try c.decode(String.self, forKey: .method)
        url = try c.decode(String.self, forKey: .url)
        requestHeaders = try c.decode([Header].self, forKey: .requestHeaders)
        requestBody = try c.decode(String.self, forKey: .requestBody)
        status = try c.decode(Int.self, forKey: .status)
        responseHeaders = try c.decode([Header].self, forKey: .responseHeaders)
        responseBody = try c.decode(String.self, forKey: .responseBody)
        durationMs = try c.decode(Int.self, forKey: .durationMs)
        mocked = try c.decode(Bool.self, forKey: .mocked)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        scripts = try c.decodeIfPresent([String].self, forKey: .scripts) ?? []
        websocket = try c.decodeIfPresent(Bool.self, forKey: .websocket) ?? false
        parseURL()
        if let saved = try c.decodeIfPresent(String.self, forKey: .app) { app = saved }
        device = try c.decodeIfPresent(String.self, forKey: .device)
    }

    private mutating func parseURL() {
        app = Self.appName(userAgent: requestHeaders.first { $0.name.lowercased() == "user-agent" }?.value ?? "")
        guard let c = URLComponents(string: url) else {
            path = url
            return
        }
        host = c.host ?? ""
        let p = c.percentEncodedPath
        path = p + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
        pathOnly = p.isEmpty ? "/" : p
        pathSegments = p.split(separator: "/").map(String.init)
    }

    static func appName(userAgent ua: String) -> String {
        if ua.isEmpty { return "Unknown" }
        if ua.hasPrefix("Mozilla/") {
            // Electron apps put their own product token before Chrome/, e.g. "Slack/4.53 Chrome/156 Electron/45".
            if ua.contains("Electron/") {
                let skip: Set<String> = ["Chrome", "Safari", "Electron", "Version", "Mobile", "AppleWebKit"]
                let tokens = ua.components(separatedBy: ") ").last?.split(separator: " ") ?? []
                if let product = tokens.lazy.compactMap({ $0.split(separator: "/").first.map(String.init) })
                    .first(where: { !skip.contains($0) }) {
                    return product == "Code" ? "Visual Studio Code" : product
                }
                return "Electron"
            }
            if ua.contains("Edg/") { return "Edge" }
            if ua.contains("Firefox/") { return "Firefox" }
            if ua.contains("Chrome/") || ua.contains("CriOS/") { return "Chrome" }
            if ua.contains("Safari/") || ua.contains("AppleWebKit/") { return "Safari" }
            return "Browser"
        }
        let token = ua.prefix { $0 != "/" && $0 != " " && $0 != "(" }
        let name = String(token).removingPercentEncoding ?? String(token)
        return name.isEmpty ? "Unknown" : name
    }

    static let maxBody = 1_000_000

    /// True when the stored response body is a placeholder (binary) or cut at `maxBody`, i.e. not the real bytes.
    public var hasPartialResponseBody: Bool {
        responseBody.hasPrefix("<binary ") || responseBody.hasSuffix(" bytes total>")
    }

    /// UTF-8 text bodies are kept up to 1 MB; binary bodies become a placeholder.
    static func text(_ data: Data) -> String {
        if data.isEmpty { return "" }
        guard let s = String(data: data.prefix(maxBody), encoding: .utf8) else {
            return "<binary \(data.count) bytes>"
        }
        return data.count > maxBody ? s + "\n<truncated, \(data.count) bytes total>" : s
    }

    /// Flow rebuilt from stored parts (e.g. an imported HAR entry).
    public init(id: String = UUID().uuidString.lowercased(), startedAt: Date, method: String, url: String,
                requestHeaders: [Header], requestBody: String, status: Int, responseHeaders: [Header], responseBody: String,
                durationMs: Int, mocked: Bool = false, error: String? = nil, scripts: [String] = [], websocket: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.method = method
        self.url = url
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.status = status
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.durationMs = durationMs
        self.mocked = mocked
        self.error = error
        self.scripts = scripts
        self.websocket = websocket
        parseURL()
    }

    public init(request: ProxyRequest, response: ProxyResponse, startedAt: Date, mocked: Bool, error: String?,
                scripts: [String] = [], websocket: Bool = false) {
        id = UUID().uuidString.lowercased()
        self.startedAt = startedAt
        method = request.method
        url = request.url
        requestHeaders = request.headers
        requestBody = Self.text(request.body)
        status = response.status
        responseHeaders = response.headers
        responseBody = Self.text(response.body)
        durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        self.mocked = mocked
        self.error = error
        self.scripts = scripts
        self.websocket = websocket
        parseURL()
        if let local = request.clientApp { app = local }
        device = request.clientDevice
    }
}

public enum HTTPReason {
    /// Standard reason phrase, e.g. 200 → "OK", 404 → "Not Found".
    public static func phrase(_ status: Int) -> String {
        HTTPResponseStatus(statusCode: status).reasonPhrase
    }
}
