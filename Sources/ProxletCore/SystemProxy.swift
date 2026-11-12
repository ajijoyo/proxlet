//
//  SystemProxy.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// macOS proxy settings and CA trust via the system CLIs (no privileged helper).
public enum SystemProxy {
    public struct CommandError: LocalizedError {
        public let output: String
        public var errorDescription: String? { output }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw CommandError(output: out) }
        return out
    }

    /// Enabled network services, e.g. "Wi-Fi", "Thunderbolt Bridge".
    static func services() throws -> [String] {
        try run("/usr/sbin/networksetup", ["-listallnetworkservices"])
            .split(separator: "\n").dropFirst()
            .map(String.init)
            .filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }

    public static func setEnabled(_ on: Bool, port: Int) throws {
        for service in try services() {
            if on {
                try run("/usr/sbin/networksetup", ["-setwebproxy", service, "127.0.0.1", "\(port)"])
                try run("/usr/sbin/networksetup", ["-setsecurewebproxy", service, "127.0.0.1", "\(port)"])
            } else {
                try run("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
                try run("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
            }
        }
    }

    /// First IPv4 address of an active non-loopback interface (what a phone on the same Wi-Fi should use).
    public static func lanIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, ip: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            candidates.append((String(cString: ifa.ifa_name), String(cString: host)))
        }
        // Prefer physical interfaces (en*) over VPN/bridge ones.
        return (candidates.first { $0.name.hasPrefix("en") } ?? candidates.first)?.ip
    }

    /// Whether the system HTTPS proxy currently points at this port.
    public static func isEnabled(port: Int) -> Bool {
        guard let out = try? run("/usr/sbin/scutil", ["--proxy"]) else { return false }
        return isEnabled(scutilOutput: out, port: port)
    }

    /// Exact field match on `scutil --proxy` output: HTTPS proxy on, pointing at 127.0.0.1:`port`.
    static func isEnabled(scutilOutput out: String, port: Int) -> Bool {
        var fields: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return fields["HTTPSEnable"] == "1" && fields["HTTPSPort"] == String(port)
            && ["127.0.0.1", "localhost"].contains(fields["HTTPSProxy"] ?? "")
    }

    /// Adds the CA to the login keychain as a trusted root (macOS asks for the password).
    public static func trustCA() throws {
        let keychain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path
        try run("/usr/bin/security", ["add-trusted-cert", "-r", "trustRoot", "-k", keychain, Paths.caCert.path])
    }

    /// Installs the CA into every booted iOS simulator.
    public static func installCAInBootedSimulators() throws {
        try run("/usr/bin/xcrun", ["simctl", "keychain", "booted", "add-root-cert", Paths.caCert.path])
    }
}
