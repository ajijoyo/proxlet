//
//  Editors.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI
import UniformTypeIdentifiers

/// Name / URL / method / match mode block shared by both editors, with a live "test your rule" field.
struct MatchingRuleSection: View {
    @Binding var name: String
    @Binding var url: String
    @Binding var method: String
    @Binding var useRegex: Bool
    @State private var testURL = ""

    var body: some View {
        GroupBox("Matching Rule") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name:").gridColumnAlignment(.trailing)
                    TextField("Name", text: $name)
                }
                GridRow {
                    Text("URL:")
                    TextField(useRegex ? "^https://api\\.example\\.com/.*" : "https://api.example.com/users/*", text: $url)
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    HStack {
                        Picker("", selection: $method) { ForEach(MockRule.methods, id: \.self) { Text($0) } }
                            .labelsHidden().frame(width: 110)
                        Picker("", selection: $useRegex) {
                            Text("Use Wildcard").tag(false)
                            Text("Use Regex").tag(true)
                        }
                        .labelsHidden().frame(width: 140)
                        Text(useRegex ? "Regex, matched anywhere in the URL." : "Wildcard * matches anything.")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
                GridRow {
                    Text("Test:")
                    HStack {
                        TextField("Paste a URL to test this rule", text: $testURL)
                        if !testURL.isEmpty {
                            let ok = !url.isEmpty && MockRule.url(testURL, matches: url, regex: useRegex)
                            Label(ok ? "Match" : "No match", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(ok ? .green : .red)
                        }
                    }
                }
            }
            .padding(6)
        }
    }
}

/// Exact file backing the editor, so it's clear which rule or script is being edited.
struct FilePathRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            Text(url.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.head)
                .help(url.path)
            Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            Spacer()
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - Map Local

struct MapLocalEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ruleID: String

    @State private var loaded: MockRule?
    @State private var name = ""
    @State private var url = ""
    @State private var method = "ANY"
    @State private var useRegex = false
    @State private var enabled = true
    @State private var message = ""
    @State private var status = ""
    /// Served instead of the message body when set (any file: image, video, PDF…).
    @State private var bodyFile: String?
    /// The text body, kept aside while a binary file is attached so removing the file brings it back.
    @State private var textBody = ""
    /// 0 = immediately, a preset in ms, or `Self.customDelay` for `customDelayMs`.
    @State private var delayChoice = 0
    @State private var customDelayMs = 500
    private static let customDelay = -1
    private static let delayPresets = [1000, 2000, 3000]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loaded == nil {
                Text("Rule \(ruleID) no longer exists.").foregroundStyle(.secondary)
            } else {
                FilePathRow(url: loaded.map(RuleStore.file(for:)) ?? RuleStore.file(ruleID))
                MatchingRuleSection(name: $name, url: $url, method: $method, useRegex: $useRegex)
                GroupBox("Map To") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Enable this rule", isOn: $enabled)
                        HStack {
                            Picker("Delay", selection: $delayChoice) {
                                Text("Immediately").tag(0)
                                ForEach(Self.delayPresets, id: \.self) { Text("\($0 / 1000) second\($0 == 1000 ? "" : "s")").tag($0) }
                                Text("Custom").tag(Self.customDelay)
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            if delayChoice == Self.customDelay {
                                TextField("ms", value: $customDelayMs, format: .number)
                                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 90)
                                Text("ms (max \(MockRule.maxDelayMs))").foregroundStyle(.secondary)
                            }
                        }
                        if let bodyFile {
                            BodyFileRow(path: bodyFile)
                        }
                        Text(bodyFile == nil ? "HTTP message format: status line, headers, blank line, body."
                             : "Status line and headers; the body is the binary file.")
                            .font(.caption).foregroundStyle(.secondary)
                        CodeTextView(text: $message, kind: .http)
                    }
                    .padding(6)
                }
                HStack {
                    Text(status).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    if bodyFile == nil {
                        Button("Select Binary File…") { selectBinaryFile() }
                        Button("Import File…") { importFile() }
                        Button("Export…") { exportFile() }
                        Button("Beautify JSON") { message = HTTPMessageFormat.beautify(message) }
                    } else {
                        Button("Remove Binary File") { removeBinaryFile() }
                    }
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
        .navigationTitle("Map Local Editor: \(name)")
        .onAppear(perform: load)
    }

    /// Loads a Map Local file in HTTP message format into the editor.
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .data]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard HTTPMessageFormat.parse(text) != nil else {
            status = "\(url.lastPathComponent) is not in HTTP message format (first line like HTTP/1.1 200 OK)."
            return
        }
        message = text
        status = "Loaded \(url.lastPathComponent); Save to apply."
    }

    /// Any file, served as is; without a Content-Type header it is typed by its extension.
    private func selectBinaryFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let parsed = HTTPMessageFormat.parse(message) {
            textBody = parsed.body
            message = HTTPMessageFormat.render(status: parsed.status, headers: parsed.headers, body: "")
        }
        bodyFile = url.path
        status = "Body: \(url.lastPathComponent); Save to apply."
    }

    private func removeBinaryFile() {
        if let parsed = HTTPMessageFormat.parse(message) {
            message = HTTPMessageFormat.render(status: parsed.status, headers: parsed.headers, body: textBody)
        }
        bodyFile = nil
        status = "Text body restored; Save to apply."
    }

    private func exportFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json, .plainText]
        let host = URLComponents(string: url.replacingOccurrences(of: "*", with: ""))?.host ?? "response"
        panel.nameFieldStringValue = HTTPMessageFormat.fileName(host: host, id: ruleID)
        guard panel.runModal() == .OK, let out = panel.url else { return }
        do { try message.write(to: out, atomically: true, encoding: .utf8) } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    private func load() {
        guard let rule = RuleStore.load().first(where: { $0.id == ruleID }) else { return }
        loaded = rule
        name = rule.name
        url = rule.urlPattern
        method = rule.method ?? "ANY"
        useRegex = rule.useRegex
        enabled = rule.enabled
        bodyFile = rule.bodyFile
        textBody = rule.body
        let delay = rule.delayMs ?? 0
        delayChoice = delay == 0 || Self.delayPresets.contains(delay) ? delay : Self.customDelay
        if delayChoice == Self.customDelay { customDelayMs = delay }
        message = HTTPMessageFormat.render(status: rule.status, headers: rule.headers, body: rule.bodyFile == nil ? rule.body : "")
    }

    private func save() {
        guard var rule = loaded else { return }
        guard let parsed = HTTPMessageFormat.parse(message) else {
            status = "First line must look like: HTTP/1.1 200"
            return
        }
        rule.name = name
        rule.urlPattern = url
        rule.method = method == "ANY" ? nil : method
        rule.useRegex = useRegex
        rule.enabled = enabled
        rule.status = parsed.status
        rule.headers = parsed.headers
        rule.body = bodyFile == nil ? parsed.body : textBody
        // A copy Proxlet made from a flow has no other owner once the rule stops using it.
        if let old = rule.bodyFile, old != bodyFile, RuleStore.isOwned(old) { try? FileManager.default.removeItem(atPath: old) }
        rule.bodyFile = bodyFile
        let delay = delayChoice == Self.customDelay ? min(max(customDelayMs, 0), MockRule.maxDelayMs) : delayChoice
        rule.delayMs = delay == 0 ? nil : delay
        do {
            try RuleStore.save(rule)
            loaded = rule
            model.reloadRules()
            dismiss()  // close the editor once saved
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}

/// The file a Map Local rule serves, with an image preview when it is one.
struct BodyFileRow: View {
    let path: String

    var body: some View {
        let type = UTType(filenameExtension: (path as NSString).pathExtension)
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
        VStack(alignment: .leading, spacing: 4) {
            Label("Body: \(path)", systemImage: "doc")
                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            if let size {
                // Only images are read for a preview; a video can be hundreds of MB.
                if type?.conforms(to: .image) == true, let data = FileManager.default.contents(atPath: path), let image = BodyImage(data) {
                    Image(nsImage: image.image).resizable().scaledToFit().frame(maxHeight: 120, alignment: .leading)
                }
                Text("\(type?.localizedDescription ?? "File") · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("File not found.").font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Script

struct ScriptEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let fileName: String

    @State private var exists = true
    @State private var name = ""
    @State private var url = ""
    @State private var method = "ANY"
    @State private var useRegex = false
    @State private var onRequest = true
    @State private var onResponse = true
    @State private var enabled = true
    @State private var code = ""
    @State private var status = ""

    private var file: URL { Paths.scripts.appendingPathComponent(fileName) }

    /// Script errors recorded on flows, newest first.
    private var console: [String] {
        model.flows.reversed().compactMap(\.error)
            .flatMap { $0.components(separatedBy: "\n") }
            .filter { $0.hasPrefix("\(fileName):") }
            .prefix(50).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !exists {
                Text("\(fileName) no longer exists.").foregroundStyle(.secondary)
            } else {
                FilePathRow(url: file)
                MatchingRuleSection(name: $name, url: $url, method: $method, useRegex: $useRegex)
                HStack {
                    Text("Run script on:")
                    Toggle("Request", isOn: $onRequest)
                    Toggle("Response", isOn: $onResponse)
                    Spacer()
                    Toggle("Enabled", isOn: $enabled).toggleStyle(.switch)
                }
                HSplitView {
                    CodeTextView(text: $code, kind: .javascript).frame(minWidth: 420)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Console").font(.headline)
                        if console.isEmpty {
                            Text("No errors. Script exceptions show up here.").foregroundStyle(.secondary).font(.caption)
                        }
                        ScrollView {
                            Text(console.joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                    .frame(minWidth: 200, idealWidth: 260)
                }
                HStack {
                    Text(status).foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Button("Save & Activate") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 900, minHeight: 620)
        .navigationTitle("Script Editor: \(name)")
        .onAppear(perform: load)
    }

    private func load() {
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            exists = false
            return
        }
        let (meta, body) = ScriptMeta.parse(source)
        name = meta.name.isEmpty ? fileName : meta.name
        url = meta.match
        method = meta.method ?? "ANY"
        useRegex = meta.useRegex
        onRequest = meta.onRequest
        onResponse = meta.onResponse
        enabled = meta.enabled
        code = body
    }

    private func save() {
        var meta = ScriptMeta()
        meta.name = name
        meta.match = url
        meta.useRegex = useRegex
        meta.method = method == "ANY" ? nil : method
        meta.onRequest = onRequest
        meta.onResponse = onResponse
        meta.enabled = enabled
        do {
            try meta.render(code: code).write(to: file, atomically: true, encoding: .utf8)
            model.reloadRules()
            dismiss()  // close the editor once saved
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
}
