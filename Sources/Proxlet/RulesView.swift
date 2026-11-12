//
//  RulesView.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI
import UniformTypeIdentifiers

/// Page header with a master enable switch and the backing folder.
struct PageHeader: View {
    let title: String
    let folder: URL
    @Binding var enabled: Bool
    let onNew: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.title2.bold())
            Spacer()
            Button("New", systemImage: "plus", action: onNew)
            Button("Reveal Folder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
            Toggle("Enabled", isOn: $enabled).toggleStyle(.switch)
        }
        .padding([.horizontal, .top], 16)
    }
}

struct MapLocalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<MockRule.ID>()

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            PageHeader(title: "Map Local", folder: Paths.rules, enabled: $model.mapLocalOn) {
                if let id = model.newRule() { openWindow(id: "mapLocal", value: id) }
            }
            HStack {
                Button("Import…", systemImage: "square.and.arrow.down") { importRules() }
                    .help("Proxlet Map Local .json, or Proxyman's MapLocalFiles-RuleTree")
                Button("Export…", systemImage: "square.and.arrow.up") { exportRules() }
                    .disabled(model.rules.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 16)
            if !model.mapLocalOn {
                Text("Map Local is off: all requests go to the network.").foregroundStyle(.orange).padding(.horizontal, 16)
            }
            List(selection: $selection) {
                if model.rules.isEmpty {
                    Text("No rules. Right-click a flow → Map Local, or use the proxlet MCP.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rules) { rule in
                    HStack {
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { model.setEnabled(rule, $0) }))
                            .labelsHidden()
                        MethodBadge(method: rule.method ?? "ANY").frame(width: 64, alignment: .leading)
                        StatusText(code: rule.status).frame(width: 40, alignment: .leading)
                        VStack(alignment: .leading) {
                            if !rule.name.isEmpty { Text(rule.name).fontWeight(.medium).lineLimit(1) }
                            Text(rule.urlPattern).lineLimit(1).truncationMode(.middle)
                                .font(rule.name.isEmpty ? .body : .caption).foregroundStyle(rule.name.isEmpty ? .primary : .secondary)
                        }
                        Spacer()
                        Button("Edit", systemImage: "pencil") { openWindow(id: "mapLocal", value: rule.id) }
                        .labelStyle(.iconOnly)
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            let name = rule.name.isEmpty ? rule.urlPattern : rule.name
                            if model.confirm("Delete Map Local rule \"\(name)\"?", "The rule will be deleted. This can't be undone.") {
                                model.delete(rule)
                            }
                        }
                        .labelStyle(.iconOnly)
                    }
                    .opacity(model.mapLocalOn ? 1 : 0.5)
                    .tag(rule.id)
                }
            }
            .contextMenu(forSelectionType: MockRule.ID.self) { ids in
                if ids.count == 1, let id = ids.first { Button("Edit", systemImage: "pencil") { openWindow(id: "mapLocal", value: id) } }
                if !ids.isEmpty {
                    Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Rules", systemImage: "trash", role: .destructive) { deleteRules(ids) }
                }
            } primaryAction: { ids in
                ids.forEach { openWindow(id: "mapLocal", value: $0) }
            }
            .onDeleteCommand { deleteRules(selection) }
        }
    }

    private func deleteRules(_ ids: Set<MockRule.ID>) {
        let rules = model.rules.filter { ids.contains($0.id) }
        guard !rules.isEmpty else { return }
        let title = rules.count == 1 ? "Delete Map Local rule \"\(rules[0].name.isEmpty ? rules[0].urlPattern : rules[0].name)\"?"
            : "Delete \(rules.count) Map Local rules?"
        guard model.confirm(title, "The rules will be deleted. This can't be undone.") else { return }
        rules.forEach(model.delete)
        selection.subtract(ids)
    }
}

extension ScriptsView {
    private func importScripts() {
        let panel = NSOpenPanel()
        panel.title = "Import Scripts"
        panel.message = "Choose a scripts file (.config)."
        panel.allowedContentTypes = [UTType(filenameExtension: "config") ?? .data, .json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let result = try Proxyman.ScriptConfig.importConfig(Data(contentsOf: url), existing: Set(model.scripts))
            try Paths.ensure()
            for script in result.scripts {
                try script.source.write(to: Paths.scripts.appendingPathComponent(script.fileName), atomically: true, encoding: .utf8)
            }
            model.reloadRules()
            let summary = "Imported \(result.scripts.count) script(s) from \(url.lastPathComponent)."
            if !result.notes.isEmpty { model.alert(([summary] + result.notes).joined(separator: "\n\n")) }
        } catch {
            model.alert("Import failed: \(error.localizedDescription)")
        }
    }

    private func exportScripts() {
        let panel = NSSavePanel()
        panel.title = "Export \(model.scripts.count) Scripts"
        panel.allowedContentTypes = [UTType(filenameExtension: "config") ?? .data]
        panel.nameFieldStringValue = "proxlet_scripting_tree_rules.config"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let files = model.scripts.map { Paths.scripts.appendingPathComponent($0) }
            try Proxyman.ScriptConfig.exportConfig(files).write(to: url, options: .atomic)
        } catch {
            model.alert("Export failed: \(error.localizedDescription)")
        }
    }
}

extension MapLocalView {
    private func importRules() {
        let panel = NSOpenPanel()
        panel.title = "Import Map Local Rules"
        panel.message = "Choose a Map Local rules file (.json or .config)."
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rules = try MapLocalArchive.importRules(Data(contentsOf: url))
            try rules.forEach(RuleStore.save)
            model.reloadRules()
            if rules.isEmpty { model.alert("No Map Local rules found in \(url.lastPathComponent).") }
        } catch {
            model.alert("Import failed: \(error.localizedDescription)")
        }
    }

    private func exportRules() {
        let panel = NSSavePanel()
        panel.title = "Export \(model.rules.count) Map Local Rules"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Proxlet Map Local.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MapLocalArchive.export(model.rules).write(to: url, options: .atomic) } catch {
            model.alert("Export failed: \(error.localizedDescription)")
        }
    }
}

struct ScriptsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<String>()

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            PageHeader(title: "Scripts", folder: Paths.scripts, enabled: $model.scriptsOn) {
                if let name = model.newScript() { openWindow(id: "script", value: name) }
            }
            HStack {
                Button("Import…", systemImage: "square.and.arrow.down") { importScripts() }
                    .help("Proxyman scripting export (.config)")
                Button("Export…", systemImage: "square.and.arrow.up") { exportScripts() }
                    .disabled(model.scripts.isEmpty)
                    .help("Proxyman-compatible .config")
                Spacer()
            }
            .padding(.horizontal, 16)
            if !model.scriptsOn {
                Text("Scripts are off: requests and responses pass through unchanged.").foregroundStyle(.orange).padding(.horizontal, 16)
            }
            List(selection: $selection) {
                if model.scripts.isEmpty {
                    Text("No scripts. Right-click a flow or path → Add Script.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.scripts, id: \.self) { name in
                    HStack {
                        Toggle("", isOn: Binding(get: { model.scriptMeta[name]?.enabled ?? true }, set: { model.setScriptEnabled(name, $0) }))
                            .labelsHidden()
                        Image(systemName: "curlybraces")
                        let meta = model.scriptMeta[name]
                        VStack(alignment: .leading) {
                            Text(meta.map { $0.name.isEmpty ? name : $0.name } ?? name).fontWeight(.medium).lineLimit(1)
                            Text(meta.map { $0.match.isEmpty ? "All requests" : $0.match } ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        if let m = meta { MethodBadge(method: m.method ?? "ANY") }
                        Spacer()
                        Button("Edit", systemImage: "pencil") { openWindow(id: "script", value: name) }
                        .labelStyle(.iconOnly)
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            let title = model.scriptMeta[name].map { $0.name.isEmpty ? name : $0.name } ?? name
                            if model.confirm("Delete script \"\(title)\"?", "The script will be deleted. You can restore \(name) from the Trash.") {
                                model.deleteScript(name)
                            }
                        }
                        .labelStyle(.iconOnly)
                    }
                    .opacity(model.scriptsOn ? 1 : 0.5)
                    .tag(name)
                }
            }
            .contextMenu(forSelectionType: String.self) { names in
                if names.count == 1, let name = names.first { Button("Edit", systemImage: "pencil") { openWindow(id: "script", value: name) } }
                if !names.isEmpty {
                    Button(names.count == 1 ? "Delete" : "Delete \(names.count) Scripts", systemImage: "trash", role: .destructive) {
                        deleteScripts(names)
                    }
                }
            } primaryAction: { names in
                names.forEach { openWindow(id: "script", value: $0) }
            }
            .onDeleteCommand { deleteScripts(selection) }
        }
    }

    private func deleteScripts(_ names: Set<String>) {
        let chosen = model.scripts.filter(names.contains)
        guard !chosen.isEmpty else { return }
        let title = chosen.count == 1 ? "Delete script \"\(model.scriptMeta[chosen[0]].map { $0.name.isEmpty ? chosen[0] : $0.name } ?? chosen[0])\"?"
            : "Delete \(chosen.count) scripts?"
        guard model.confirm(title, "The scripts will be moved to the Trash, where you can restore them.") else { return }
        chosen.forEach(model.deleteScript)
        selection.subtract(names)
    }
}
