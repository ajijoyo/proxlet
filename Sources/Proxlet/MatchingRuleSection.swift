//
//  MatchingRuleSection.swift
//  Proxlet
//
//  Created by Aji on 15/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI

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

