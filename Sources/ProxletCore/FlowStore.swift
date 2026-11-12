//
//  FlowStore.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Appends completed flows to flows.jsonl and notifies the UI.
public final class FlowStore: @unchecked Sendable {
    public var onAppend: (@Sendable (Flow) -> Void)?
    /// When false, traffic is still proxied but nothing is recorded.
    public var isRecording: Bool {
        get { lock.withLock { recording } }
        set { lock.withLock { recording = newValue } }
    }
    private var recording = true
    private let lock = NSLock()
    /// flows.jsonl is rotated to flows.1.jsonl past this size; lowered in tests.
    nonisolated(unsafe) static var maxFileSize = 50_000_000

    public init() {}

    /// `force` records even while paused (used for imported sessions); `responseBody` is kept when it's an image.
    public func append(_ flow: Flow, force: Bool = false, responseBody: Data? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard recording || force else { return }
        do {
            try Paths.ensure()
            rotateIfNeeded()
            try Self.appendLine(Self.encoder.encode(flow), to: Paths.flows)
            if let responseBody { BodyStore.saveIfImage(responseBody, for: flow) }
        } catch {
            NSLog("Proxlet: failed to write flow: \(error)")
        }
        onAppend?(flow)
    }

    /// Appends `data` plus a newline to a JSONL file, creating it if needed.
    static func appendLine(_ data: Data, to url: URL) throws {
        var line = data
        line.append(0x0A)
        guard let handle = try? FileHandle(forWritingTo: url) else { return try line.write(to: url) }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Rewrites flows.jsonl without the given flows.
    public func delete(ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: Paths.flows) else { return }
        let kept = data.split(separator: 0x0A).filter { line in
            guard let flow = try? Self.decoder.decode(Flow.self, from: Data(line)) else { return true }
            return !ids.contains(flow.id)
        }
        var out = Data(kept.joined(separator: [0x0A]))
        if !out.isEmpty { out.append(0x0A) }
        try? out.write(to: Paths.flows, options: .atomic)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: Paths.flows)
    }

    /// Reads all flows, oldest first.
    public static func load() -> [Flow] {
        guard let data = try? Data(contentsOf: Paths.flows) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Flow.self, from: Data($0)) }
    }

    private func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: Paths.flows.path)[.size] as? Int) ?? 0
        guard size > Self.maxFileSize else { return }
        let old = Paths.root.appendingPathComponent("flows.1.jsonl")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: Paths.flows, to: old)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
