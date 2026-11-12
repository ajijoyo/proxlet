//
//  AccessControlView.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI

struct AccessControlMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Access Control…") { openWindow(id: "access") }
            .keyboardShortcut("a", modifiers: [.command, .option])
    }
}

/// Network devices allowed to use the proxy; this Mac, simulators and emulators never need an entry.
struct AccessControlView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: AccessControl.Mode = .ask
    @State private var allowed: [String] = []
    @State private var selection: Set<String> = []
    @State private var newIP = ""
    @State private var invalid = false
    // Devices allowed from the connection prompt show up without reopening the window.
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("New devices", selection: $mode) {
                Text("Ask before allowing").tag(AccessControl.Mode.ask)
                Text("Allow all").tag(AccessControl.Mode.allowAll)
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text("\(allowed.count) allowed device\(allowed.count == 1 ? "" : "s")").font(.headline)
            List(allowed, id: \.self, selection: $selection) { ip in
                Text(ip).font(.system(.body, design: .monospaced))
            }
            .contextMenu(forSelectionType: String.self) { ips in
                Button("Delete") { delete(ips) }
            }
            .onDeleteCommand { delete(selection) }
            .border(.separator)
            HStack {
                TextField("IP address, e.g. 192.168.1.20", text: $newIP)
                    .textFieldStyle(.roundedBorder).onSubmit(add)
                    .onChange(of: newIP) { invalid = false }
                Button("Add", action: add).disabled(newIP.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Delete") { delete(selection) }.disabled(selection.isEmpty)
            }
            if invalid {
                Text("Not a valid IPv4/IPv6 address, or it is already in the list.").font(.caption).foregroundStyle(.red)
            }
            Text("This Mac, its simulators and Android emulators are always allowed. In Ask mode, other devices are asked "
                 + "once; denied devices stay blocked until Proxlet restarts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
        .onAppear {
            mode = model.access.mode
            reload()
        }
        .onReceive(refresh) { _ in reload() }
        .onChange(of: mode) { model.access.mode = mode }
    }

    private func reload() {
        let now = model.access.allowed
        if now != allowed { allowed = now }
    }

    private func add() {
        if model.access.add(newIP) {
            newIP = ""
            reload()
        } else {
            invalid = true
        }
    }

    private func delete(_ ips: Set<String>) {
        guard !ips.isEmpty, model.confirm("Delete \(ips.count == 1 ? ips.first! : "\(ips.count) devices")?",
                                          "Deleted devices are asked again the next time they connect.") else { return }
        model.access.remove(ips)
        selection.subtract(ips)
        reload()
    }
}
