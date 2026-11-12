//
//  AndroidEmulator.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// adb helpers for Android emulators; the emulator reaches the Mac at 10.0.2.2.
public enum AndroidEmulator {
    public static let hostAlias = "10.0.2.2"
    public static let deviceCertPath = "/sdcard/Download/Proxlet-CA.crt"

    /// Apps launched from Finder get a minimal PATH, so look in the usual SDK locations.
    public static func adbPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"]].compactMap { $0 }.map { "\($0)/platform-tools/adb" }
            + ["\(home)/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func adb(_ args: [String]) throws -> String {
        guard let adb = adbPath() else { throw SystemProxy.CommandError(output: "adb not found. Install Android SDK platform-tools.") }
        return try SystemProxy.run(adb, args)
    }

    /// Serials of running emulators, e.g. `emulator-5554`.
    public static func devices() throws -> [String] {
        try parseDevices(adb(["devices"]))
    }

    static func parseDevices(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard cols.count >= 2, cols[0].hasPrefix("emulator-"), cols[1] == "device" else { return nil }
            return String(cols[0])
        }
    }

    public static func setProxy(serial: String, port: Int) throws {
        try adb(proxyArgs(serial: serial, value: "\(hostAlias):\(port)"))
    }

    /// `adb` arguments that set the emulator's global HTTP proxy (`:0` clears it).
    static func proxyArgs(serial: String, value: String) -> [String] {
        ["-s", serial, "shell", "settings", "put", "global", "http_proxy", value]
    }

    public static func clearProxy(serial: String) throws {
        try adb(proxyArgs(serial: serial, value: ":0"))
    }

    /// Copies the CA to Downloads and opens Security settings to finish the install.
    public static func pushCA(serial: String) throws {
        try adb(["-s", serial, "push", Paths.caCert.path, deviceCertPath])
        try adb(["-s", serial, "shell", "am", "start", "-a", "android.settings.SECURITY_SETTINGS"])
    }

    /// Current `http_proxy` value on the emulator ("null" or ":0" when unset).
    public static func proxy(serial: String) throws -> String {
        try adb(["-s", serial, "shell", "settings", "get", "global", "http_proxy"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
