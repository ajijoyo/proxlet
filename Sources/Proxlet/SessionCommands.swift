//
//  SessionCommands.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AppKit
import ProxletCore
import SwiftUI
import UniformTypeIdentifiers

/// File › Import / Export Session (.chls for Charles, .har for other proxies and browsers).
enum SessionFiles {
    static let chls = UTType(filenameExtension: "chls") ?? .data
    static let har = UTType(filenameExtension: "har") ?? .json

    @MainActor
    static func export(_ flows: [Flow], model: AppModel) {
        guard !flows.isEmpty else { return model.alert("No flows to export.") }
        let panel = NSSavePanel()
        panel.title = "Export \(flows.count) Flows"
        panel.allowedContentTypes = [chls, har]
        panel.nameFieldStringValue = "Proxlet Session.chls"
        panel.message = ".chls opens in Charles and Proxyman (needs Charles installed to write). .har opens in Proxyman, Charles and browsers."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached {
            do { try SessionArchive.export(flows, to: url) } catch {
                await MainActor.run { model.alert("Export failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Imports sessions (.chls/.har) and response files (.json/.txt in HTTP message format → Map Local rules).
    @MainActor
    static func importSession(model: AppModel, openRule: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Import Session or Map Local File"
        panel.allowedContentTypes = [chls, har, .json, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var sessions: [URL] = []
        var ruleIDs: [String] = []
        for url in panel.urls {
            let head = (try? FileHandle(forReadingFrom: url).read(upToCount: 16)).flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } } ?? ""
            if head.hasPrefix("HTTP/") || isPlainResponseFile(url) {
                guard let rule = HTTPMessageFormat.rule(fromFile: url) else {
                    model.alert("Could not read \(url.lastPathComponent).")
                    continue
                }
                do {
                    try RuleStore.save(rule)
                    ruleIDs.append(rule.id)
                } catch {
                    model.alert("Import failed: \(error.localizedDescription)")
                }
            } else {
                sessions.append(url)
            }
        }
        if !ruleIDs.isEmpty {
            model.reloadRules()
            // Open the editor so the guessed URL pattern can be checked.
            ruleIDs.prefix(3).forEach(openRule)
        }
        guard !sessions.isEmpty else { return }
        Task.detached {
            do {
                let imported = try sessions.flatMap { try SessionArchive.importFile($0) }
                await MainActor.run { model.addImported(imported) }
            } catch {
                await MainActor.run { model.alert("Import failed: \(error.localizedDescription)") }
            }
        }
    }

    /// A .json/.txt that is neither HAR nor a Map Local export: treat it as a response body.
    static func isPlainResponseFile(_ url: URL) -> Bool {
        guard ["json", "txt"].contains(url.pathExtension.lowercased()), let data = try? Data(contentsOf: url) else { return false }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
        return obj["log"] == nil
    }

    /// Saves one flow's response as a Map Local file in HTTP message format.
    @MainActor
    static func exportResponse(_ flow: Flow, model: AppModel) {
        let panel = NSSavePanel()
        panel.title = "Export Response"
        panel.allowedContentTypes = [.json, .plainText]
        panel.nameFieldStringValue = HTTPMessageFormat.fileName(for: flow)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try HTTPMessageFormat.render(response: flow).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.alert("Export failed: \(error.localizedDescription)")
        }
    }
}

struct SessionMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Import…") { SessionFiles.importSession(model: model) { openWindow(id: "mapLocal", value: $0) } }
            .keyboardShortcut("o", modifiers: .command)
        Button("Export Session…") { SessionFiles.export(model.flows, model: model) }
            .keyboardShortcut("e", modifiers: [.command, .shift])
    }
}
