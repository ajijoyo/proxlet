//
//  AppModel+Certificate.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AppKit
import ProxletCore

extension AppModel {
    /// After a regenerate: what to redo where, then the macOS trust prompt.
    func showNewCASteps() {
        let next = NSAlert()
        next.messageText = "New CA created"
        next.informativeText = """
            Next steps:
            1. This Mac: Proxlet opens the macOS trust prompt next. Approve it with your password or Touch ID.
            2. Simulators: Certificate › Simulator (all booted). Simulators that aren't booted need it later too.
            3. Real devices: remove the old Proxlet CA profile, then install the new one (Certificate › Real Device…). \
            On iPhone, also turn it on in Settings › General › About › Certificate Trust Settings.
            Until then, HTTPS through Proxlet fails on that device.
            """
        next.addButton(withTitle: "Continue")
        next.runModal()
        runTask("Trust CA") { try SystemProxy.trustCA() }
    }
}
