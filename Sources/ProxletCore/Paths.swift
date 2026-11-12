//
//  Paths.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Shared on-disk state read by both the app and proxlet-mcp.
public enum Paths {
    /// Keep in sync with CFBundleShortVersionString in make-app.sh.
    /// The only place the version is set; make-app.sh copies it into Info.plist.
    public static let appVersion = "0.1.1"

    public static var root: URL = {
        if let custom = ProcessInfo.processInfo.environment["PROXLET_HOME"] {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Proxlet", isDirectory: true)
    }()

    public static var rules: URL { root.appendingPathComponent("rules", isDirectory: true) }
    public static var scripts: URL { root.appendingPathComponent("scripts", isDirectory: true) }
    public static var flows: URL { root.appendingPathComponent("flows.jsonl") }
    public static var caCert: URL { root.appendingPathComponent("ca.pem") }
    public static var caKey: URL { root.appendingPathComponent("ca-key.pem") }
    public static var access: URL { root.appendingPathComponent("access.json") }
    public static var sslProxying: URL { root.appendingPathComponent("ssl-proxying.json") }
    /// Binary Map Local bodies Proxlet owns (copied from captured flows); deleted with their rule.
    public static var mapLocalFiles: URL { root.appendingPathComponent("map-local-files", isDirectory: true) }

    public static func ensure() throws {
        for dir in [root, rules, scripts] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
