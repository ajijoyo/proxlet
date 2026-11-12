//
//  SharedState.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// App-level switches shared between Proxlet.app and proxlet-mcp via `state.json`.
/// The app writes it on every change and polls it, so MCP edits apply within ~2 s.
public struct SharedState: Codable, Equatable, Sendable {
    public var recording = true
    public var mapLocal = true
    public var scripts = true
    /// Strip caching from all traffic (Map Local and scripted traffic is never cacheable either way).
    public var noCaching = false
    /// Written by the app; read-only for MCP.
    public var port = SharedState.defaultPort
    public var running = false
    public var lanIP: String?
    /// Set by MCP `clear_session`; the app drops its in-memory flows when this changes.
    public var clearedAt: Date?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recording = try c.decodeIfPresent(Bool.self, forKey: .recording) ?? true
        mapLocal = try c.decodeIfPresent(Bool.self, forKey: .mapLocal) ?? true
        scripts = try c.decodeIfPresent(Bool.self, forKey: .scripts) ?? true
        noCaching = try c.decodeIfPresent(Bool.self, forKey: .noCaching) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? SharedState.defaultPort
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        lanIP = try c.decodeIfPresent(String.self, forKey: .lanIP)
        clearedAt = try c.decodeIfPresent(Date.self, forKey: .clearedAt)
    }

    public static let defaultPort = 9191

    static var file: URL { Paths.root.appendingPathComponent("state.json") }

    // Fractional seconds, so two clear_session calls within one second still compare unequal.
    static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        return enc
    }()

    static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return dec
    }()
    private static let lock = NSLock()

    public static func load() -> SharedState {
        guard let data = try? Data(contentsOf: file) else { return SharedState() }
        return (try? decoder.decode(SharedState.self, from: data)) ?? SharedState()
    }

    /// Read-modify-write; returns the saved state.
    @discardableResult
    public static func update(_ change: (inout SharedState) -> Void) -> SharedState {
        lock.lock()
        defer { lock.unlock() }
        var state = load()
        change(&state)
        try? Paths.ensure()
        try? encoder.encode(state).write(to: file, options: .atomic)
        return state
    }
}
