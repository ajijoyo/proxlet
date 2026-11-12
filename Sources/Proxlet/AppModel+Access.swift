//
//  AppModel+Access.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AppKit
import ProxletCore

extension AppModel {
    /// Prompt for a device on the network that isn't on the allow list yet.
    func askAccess(_ ip: String) -> Bool {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Allow \(ip) to use Proxlet?"
        a.informativeText = "A device on your network is connecting through Proxlet. "
            + "Allow only devices you own: an allowed device can see and use everything this Mac can reach."
        a.addButton(withTitle: "Allow")
        a.addButton(withTitle: "Deny")
        return a.runModal() == .alertFirstButtonReturn
    }
}
