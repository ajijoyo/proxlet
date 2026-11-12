//
//  SSLProxyingView.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI

struct SSLProxyingMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("SSL Proxying List…") { openWindow(id: "sslProxying") }
            .keyboardShortcut("s", modifiers: [.command, .option])
    }
}

/// Include/exclude domains for decryption.
struct SSLProxyingView: View {
    @Environment(AppModel.self) private var model
    @State private var list: SSLProxying.List = .include
    @State private var selection: Set<String> = []
    @State private var newDomain = ""
    @State private var invalid = false

    private var entries: [SSLProxying.Entry] { model.sslProxying.entries(list) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("List", selection: $list) {
                Text("Include (decrypt)").tag(SSLProxying.List.include)
                Text("Exclude (never decrypt)").tag(SSLProxying.List.exclude)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: list) { selection.removeAll() }
            Text("\(entries.count) domain\(entries.count == 1 ? "" : "s")").font(.headline)
            List(entries, id: \.domain, selection: $selection) { entry in
                Toggle(isOn: Binding(
                    get: { entry.enabled },
                    set: { on in model.updateSSLProxying { $0.setEnabled(on, domain: entry.domain, list: list) } }
                )) {
                    Text(entry.domain).font(.system(.body, design: .monospaced))
                }
            }
            .contextMenu(forSelectionType: String.self) { domains in
                Button("Delete") { delete(domains) }
            }
            .onDeleteCommand { delete(selection) }
            .border(.separator)
            HStack {
                TextField("Domain, e.g. api.example.com or *.example.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder).onSubmit(add)
                    .onChange(of: newDomain) { invalid = false }
                Button("Add", action: add).disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Delete") { delete(selection) }.disabled(selection.isEmpty)
            }
            if invalid {
                Text("Not a host name or *.host pattern.").font(.caption).foregroundStyle(.red)
            }
            Text("Only HTTPS hosts matching an enabled Include entry, and no enabled Exclude entry, are decrypted. Other HTTPS "
                 + "traffic passes through untouched: only its CONNECT shows up, and Map Local and scripts don't apply to it. "
                 + "Right-click a domain in the sidebar to enable it quickly.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 420)
    }

    private func add() {
        guard SSLProxying.normalize(newDomain) != nil else { return invalid = true }
        model.updateSSLProxying { $0.add(newDomain, to: list) }
        newDomain = ""
    }

    private func delete(_ domains: Set<String>) {
        guard !domains.isEmpty, model.confirm("Delete \(domains.count == 1 ? domains.first! : "\(domains.count) domains")?",
                                              "Their HTTPS traffic is no longer affected by this list.") else { return }
        model.updateSSLProxying { list in for d in domains { list.remove(d, from: self.list) } }
        selection.subtract(domains)
    }
}
