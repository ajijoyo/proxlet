//
//  SetupTools.swift
//  proxlet-mcp
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
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
