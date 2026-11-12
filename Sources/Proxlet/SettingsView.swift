//
//  SettingsView.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var portText = ""

    private var newPort: Int? { Int(portText).flatMap { (1024...65535).contains($0) ? $0 : nil } }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Proxy") {
                HStack {
                    TextField("Port", text: $portText).frame(width: 90).onSubmit(apply)
                    Button("Apply", action: apply).disabled(newPort == nil || newPort == model.port)
                    Text(model.running ? "Listening on \(String(model.port))" : "Not running")
                        .foregroundStyle(model.running ? .green : .red)
                }
                Text("1024–65535. After changing it, update the proxy on phones and run Set Proxy again for emulators; "
                     + "the Mac's system proxy follows automatically.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Certificate") {
                LabeledContent("New CA valid for") {
                    HStack {
                        TextField("Days", value: $model.caValidityDays, format: .number)
                            .textFieldStyle(.roundedBorder).labelsHidden().multilineTextAlignment(.trailing).frame(width: 80)
                        Text("days (max \(CertificateAuthority.validityRange.upperBound))").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if let expiry = model.caExpiry {
                        Text("Current CA expires \(expiry.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(expiry < Date().addingTimeInterval(86_400 * 30) ? .orange : .primary)
                    }
                    Spacer()
                    Button("Regenerate CA…") { Task { await model.regenerateCA() } }
                }
                Text("The lifetime applies to the next CA only. After regenerating, trust the new CA again on this Mac, "
                     + "simulators and devices (Certificate menu).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { portText = String(model.port) }
    }

    private func apply() {
        guard let p = newPort else { return }
        Task { await model.changePort(p) }
    }
}
