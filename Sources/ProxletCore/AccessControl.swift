//
//  AccessControl.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Which network clients may use the proxy. This Mac (simulators, emulators via 10.0.2.2) is always allowed.
public final class AccessControl: @unchecked Sendable {
    public enum Mode: String, Codable, Sendable {
        case ask, allowAll
    }

    struct Stored: Codable {
        var mode: Mode = .ask
        var allowed: [String] = []
    }

    /// Asks the user whether a new client IP may connect; unset means deny.
    public var ask: (@Sendable (String) async -> Bool)?
    private let lock = NSLock()
    private var stored: Stored
    /// Denied for this run only, so a stray device doesn't prompt on every connection.
    private var denied: Set<String> = []
    private var pending: [String: Task<Bool, Never>] = [:]

    /// access.json's date when last read; proxlet-mcp edits it too, so a newer file is re-read.
    private var loadedModified: Date?

    public init() {
        stored = Stored()
        syncFromDisk()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.withLock {
            syncFromDisk()
            return body()
        }
    }

    /// Caller holds `lock` (or is `init`).
    private func syncFromDisk() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: Paths.access.path))?[.modificationDate] as? Date
        guard modified != loadedModified else { return }
        loadedModified = modified
        stored = (try? JSONDecoder().decode(Stored.self, from: Data(contentsOf: Paths.access))) ?? Stored()
    }

    public var mode: Mode {
        get { locked { stored.mode } }
        set { locked { stored.mode = newValue; save() } }
    }

    public var allowed: [String] { locked { stored.allowed } }

    /// Adds an IPv4/IPv6 address by hand; false when it isn't one or is already listed.
    @discardableResult
    public func add(_ ip: String) -> Bool {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        guard Self.isIP(ip) else { return false }
        return locked {
            guard !stored.allowed.contains(ip) else { return false }
            stored.allowed.append(ip)
            denied.remove(ip)
            save()
            return true
        }
    }

    public func remove(_ ips: Set<String>) {
        locked { stored.allowed.removeAll { ips.contains($0) }; save() }
    }

    public static func isIP(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// Concurrent connections from one new IP share a single prompt.
    public func isAllowed(_ ip: String) async -> Bool {
        if Self.isLocal(ip) { return true }
        let (decided, task): (Bool?, Task<Bool, Never>?) = locked {
            if stored.mode == .allowAll || stored.allowed.contains(ip) { return (true, nil) }
            if denied.contains(ip) { return (false, nil) }
            if let t = pending[ip] { return (nil, t) }
            let ask = self.ask
            let t = Task { await ask?(ip) ?? false }
            pending[ip] = t
            return (nil, t)
        }
        if let decided { return decided }
        guard let task else { return false }
        let ok = await task.value
        locked {
            guard pending.removeValue(forKey: ip) != nil else { return }
            if ok {
                stored.allowed.append(ip)
                save()
            } else {
                denied.insert(ip)
            }
        }
        return ok
    }

    static func isLocal(_ ip: String) -> Bool {
        ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("::ffff:127.")
    }

    /// Caller holds `lock`.
    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(stored).write(to: Paths.access, options: .atomic)
        loadedModified = (try? FileManager.default.attributesOfItem(atPath: Paths.access.path))?[.modificationDate] as? Date
    }
}
