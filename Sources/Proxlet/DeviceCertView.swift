//
//  DeviceCertView.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import CoreImage.CIFilterBuiltins
import ProxletCore
import SwiftUI

/// Certificate menu grouped by platform; a View so it can open windows.
struct CertificateMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("macOS") {
            Button("Trust CA on this Mac") { model.runTask("Trust CA") { try SystemProxy.trustCA() } }
        }
        Section("iOS") {
            Button("Simulator (all booted)") {
                model.runTask("Simulator CA") { try SystemProxy.installCAInBootedSimulators() }
            }
            Button("Real Device…") { openWindow(id: "deviceCert", value: "ios") }
        }
        Section("Android") {
            Button("Emulator…") { openWindow(id: "deviceCert", value: "emulator") }
            Button("Real Device…") { openWindow(id: "deviceCert", value: "android") }
        }
        Divider()
        Button("Reveal Data Folder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.root]) }
    }
}

/// Step-by-step guide plus a QR code pointing at Proxlet's own CA download page.
struct DeviceCertView: View {
    @Environment(AppModel.self) private var model
    let platform: String

    private var isIOS: Bool { platform == "ios" }
    private var ip: String { model.lanIP ?? "<this Mac's IP>" }
    private var port: String { String(model.port) }
    private var downloadURL: String { "http://\(ip):\(port)/\(isIOS ? "ssl.pem" : "ssl.crt")" }

    private var steps: [String] {
        if isIOS {
            [
                "Connect the iPhone to the same Wi-Fi as this Mac.",
                "Scan the QR code with the Camera, or open \(downloadURL) in Safari. Tap Allow to download the profile.",
                "Settings › General › VPN & Device Management › Proxlet CA › Install.",
                "Settings › General › About › Certificate Trust Settings › turn on Proxlet CA.",
                "Settings › Wi-Fi › (i) › Configure Proxy › Manual. Server \(ip), Port \(port).",
            ]
        } else {
            [
                "Connect the phone to the same Wi-Fi as this Mac.",
                "Scan the QR code, or open \(downloadURL) in Chrome to download Proxlet-CA.crt.",
                "Settings › Security & privacy › More security settings › Encryption & credentials › "
                    + "Install a certificate › CA certificate › pick Proxlet-CA.crt.",
                "Wi-Fi › long-press the network › Modify › Proxy: Manual. Host \(ip), Port \(port).",
                "Apps on Android 7+ only trust this CA if their network_security_config allows user certificates "
                    + "(e.g. a debug build with <certificates src=\"user\"/>). Chrome trusts it.",
            ]
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text(isIOS ? "Install on iOS Device" : "Install on Android Device").font(.title2.bold())
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).").bold().frame(width: 20, alignment: .trailing)
                        Text(step).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Text(downloadURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(downloadURL, forType: .string)
                    }
                }
                if !model.running {
                    Text("Proxlet is not running, the link will not work.").foregroundStyle(.red)
                }
            }
            if let qr = Self.qrCode(downloadURL) {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 200, height: 200)
                    .padding(8).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 360)
        .navigationTitle(isIOS ? "Install CA on iOS" : "Install CA on Android")
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// Lists running Android emulators with one-click proxy and CA setup over adb.
struct AndroidEmulatorView: View {
    @Environment(AppModel.self) private var model
    @State private var devices: [String] = []
    @State private var proxies: [String: String] = [:]
    @State private var status = ""
    @State private var busy = false

    private var target: String { "\(AndroidEmulator.hostAlias):\(model.port)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Install on Android Emulator").font(.title2.bold())
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }.disabled(busy)
            }
            Text("The emulator reaches this Mac at \(AndroidEmulator.hostAlias), so its proxy is set to \(target).")
                .foregroundStyle(.secondary)

            if AndroidEmulator.adbPath() == nil {
                Text("adb not found. Install Android SDK platform-tools (Android Studio › SDK Manager).").foregroundStyle(.red)
            } else if devices.isEmpty {
                Text("No running emulator. Start one from Android Studio › Device Manager, then Refresh.")
                    .foregroundStyle(.secondary)
            }

            ForEach(devices, id: \.self) { serial in
                GroupBox {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(serial).bold()
                            Text("Proxy: \(proxies[serial] ?? "…")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Set Proxy") {
                            let port = model.port
                            run(serial, "Proxy set") { try AndroidEmulator.setProxy(serial: serial, port: port) }
                        }
                        Button("Push CA & Open Settings") {
                            run(serial, "CA copied to \(AndroidEmulator.deviceCertPath)") { try AndroidEmulator.pushCA(serial: serial) }
                        }
                        Button("Clear Proxy") { run(serial, "Proxy cleared") { try AndroidEmulator.clearProxy(serial: serial) } }
                    }
                    .disabled(busy)
                    .padding(4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Finish the CA install on the emulator:").bold()
                Text("Settings › Security & privacy › More security settings › Encryption & credentials › "
                     + "Install a certificate › CA certificate › Download › Proxlet-CA.crt.")
                Text("Apps only trust user CAs when their network_security_config allows it "
                     + "(e.g. a debug build with <certificates src=\"user\"/>). Chrome trusts it.")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 380)
        .navigationTitle("Install CA on Android Emulator")
        .onAppear(perform: refresh)
    }

    private func refresh() {
        busy = true
        Task.detached {
            let found = (try? AndroidEmulator.devices()) ?? []
            var map: [String: String] = [:]
            for serial in found { map[serial] = (try? AndroidEmulator.proxy(serial: serial)) ?? "unknown" }
            let proxyMap = map
            await MainActor.run {
                devices = found
                proxies = proxyMap
                busy = false
            }
        }
    }

    private func run(_ serial: String, _ done: String, _ work: @escaping @Sendable () throws -> Void) {
        busy = true
        Task.detached {
            let result: String
            do {
                try work()
                result = "\(serial): \(done)"
            } catch {
                result = "\(serial): \(error.localizedDescription)"
            }
            await MainActor.run {
                status = result
                busy = false
                refresh()
            }
        }
    }
}
