//
//  AppDelegate.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AppKit
import ProxletCore

/// Turns the Mac's proxy off when Proxlet quits, so traffic isn't left pointing at a dead port.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill` / Activity Monitor › Quit send SIGTERM; route it through the normal quit path.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        termSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // MCP reads this; without it, set_system_proxy would point the Mac at a dead port.
        SharedState.update { $0.running = false }
        let port = AppModel.storedPort
        // Only undo our own setting; a proxy pointing elsewhere (another tool) is left alone.
        guard SystemProxy.isEnabled(port: port) else { return }
        try? SystemProxy.setEnabled(false, port: port)
    }
}
