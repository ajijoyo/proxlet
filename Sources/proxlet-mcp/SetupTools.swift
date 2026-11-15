//
//  SetupTools.swift
//  proxlet-mcp
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the GNU General Public License v3.0.
//

import Foundation
import ProxletCore

func getCertificateStatus(_: Args) throws -> String {
    guard let ca = CertificateAuthority.status() else {
        return try json(any: ["exists": false, "path": Paths.caCert.path, "note": "Proxlet creates its CA on first start."])
    }
    let days = Int(ca.notAfter.timeIntervalSinceNow / 86_400)
    let iso = ISO8601DateFormatter()
    return try json(any: [
        "exists": true, "path": Paths.caCert.path, "subject": ca.subject, "sha256": ca.sha256,
        "not_before": iso.string(from: ca.notBefore), "not_after": iso.string(from: ca.notAfter),
        "expired": days < 0, "days_left": days, "trusted_on_this_mac": ca.trusted,
        "note": "Simulators and devices keep their own trust; this only reflects this Mac's keychain.",
    ])
}

func getVersion(_: Args) throws -> String {
    try json(any: ["name": "Proxlet", "version": Paths.appVersion])
}

/// Device access: this Mac is always allowed.
func getAccessControl(_: Args) throws -> String {
    let access = AccessControl()
    return try json(any: ["mode": access.mode == .ask ? "ask" : "allow_all", "allowed": access.allowed,
                          "note": "Loopback (this Mac, simulators, emulators) is always allowed."])
}

func setAccessControlMode(_ a: Args) throws -> String {
    let raw = try a.required("mode")
    guard let mode = ["ask": AccessControl.Mode.ask, "allow_all": .allowAll][raw] else {
        throw ToolError(message: "mode must be ask or allow_all")
    }
    AccessControl().mode = mode
    return "New devices: \(raw == "ask" ? "asked before allowing" : "all allowed")"
}

func allowDevice(_ a: Args) throws -> String {
    let ip = try a.required("ip")
    guard AccessControl().add(ip) else { throw ToolError(message: "\(ip) is not an IPv4/IPv6 address, or is already allowed") }
    return "Allowed \(ip.trimmingCharacters(in: .whitespaces))"
}

func removeDevice(_ a: Args) throws -> String {
    let ip = try a.required("ip")
    let access = AccessControl()
    guard access.allowed.contains(ip) else { throw ToolError(message: "\(ip) is not in the allow list") }
    access.remove([ip])
    return "Removed \(ip); it is asked again on its next connection"
}

/// Launches Proxlet.app in the background if needed and waits until its proxy listens.
func openProxlet(_: Args) throws -> String {
    if exitCode("/usr/bin/pgrep", ["-x", "Proxlet"]) == 0, SharedState.load().running {
        return "Proxlet is already running on 127.0.0.1:\(SharedState.load().port)"
    }
    let start = Date()
    guard exitCode("/usr/bin/open", ["-g", "-b", "com.git.proxlet"]) == 0 else {
        throw ToolError(message: "Proxlet.app not found; install it with ./make-app.sh")
    }
    // A crashed app can leave running=true behind, so only trust a state.json written after launch.
    for _ in 0..<60 {
        let written = (try? SharedState.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let state = SharedState.load()
        if state.running, let written, written >= start { return "Proxlet started on 127.0.0.1:\(state.port)" }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw ToolError(message: "Proxlet opened but its proxy didn't start within 15 s; check the app (port in use?)")
}

private func exitCode(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}
