//
//  ProxletApp.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import SwiftUI

@main
struct ProxletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // Needed when launched as a bare SwiftPM executable (no .app bundle).
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Proxlet") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            // Replaces File › New (it only opened empty editor windows); editors open from Map Local / Scripts.
            CommandGroup(replacing: .newItem) {
                SessionMenu(model: model)
            }
            CommandMenu("Certificate") {
                CertificateMenu(model: model)
            }
            CommandMenu("Proxy") {
                Toggle("No Caching", isOn: Bindable(model).noCachingOn)
                Divider()
                AccessControlMenu()
                SSLProxyingMenu()
            }
        }
        WindowGroup("Map Local Editor", id: "mapLocal", for: String.self) { $id in
            if let id { MapLocalEditor(ruleID: id).environment(model) }
        }
        WindowGroup("Script Editor", id: "script", for: String.self) { $name in
            if let name { ScriptEditor(fileName: name).environment(model) }
        }
        Settings {
            SettingsView().environment(model)
        }
        Window("Access Control", id: "access") {
            AccessControlView().environment(model)
        }
        Window("SSL Proxying", id: "sslProxying") {
            SSLProxyingView().environment(model)
        }
        WindowGroup("Install Certificate", id: "deviceCert", for: String.self) { $platform in
            if platform == "emulator" {
                AndroidEmulatorView().environment(model)
            } else if let platform {
                DeviceCertView(platform: platform).environment(model)
            }
        }
    }
}
