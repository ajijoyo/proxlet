//
//  WebSocketPane.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI

/// Live list of a WebSocket flow's messages with a JSON-aware viewer for the selected one.
struct WebSocketPane: View {
    let flow: Flow
    @State private var messages: [WebSocketMessage] = []
    @State private var selected: Int?
    @State private var split: CGFloat = 0.55
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Messages").font(.headline)
                Text("\(messages.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let i = selected, messages.indices.contains(i) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(JSONFormatter.pretty(messages[i].text) ?? messages[i].text, forType: .string)
                    }
                    .labelStyle(.iconOnly).help("Copy")
                }
            }
            ResizableSplit(axis: .vertical, fraction: $split, minFirst: 80, minSecond: 80) {
                List(selection: $selected) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                        HStack(spacing: 8) {
                            Image(systemName: m.direction == "send" ? "arrow.up" : "arrow.down")
                                .foregroundStyle(m.direction == "send" ? .green : .blue)
                                .help(m.direction == "send" ? "Sent by the client" : "Received from the server")
                            Text(m.type).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                            Text(m.text).lineLimit(1).truncationMode(.tail)
                            Spacer()
                            Text("\(m.size) B").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            Text(FlowListView.time.string(from: m.time)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .tag(i)
                    }
                }
            } second: {
                ScrollView {
                    Group {
                        if let i = selected, messages.indices.contains(i) {
                            let text = messages[i].text
                            if let pretty = JSONFormatter.pretty(text) {
                                Text(Syntax.attributed(pretty, kind: .json, dark: colorScheme == .dark))
                            } else {
                                Text(text)
                            }
                        } else {
                            Text(messages.isEmpty ? "No messages yet" : "Select a message").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 4)
        // Messages are appended to disk by the proxy; poll while this flow is shown.
        .task(id: flow.id) {
            while !Task.isCancelled {
                let loaded = await Task.detached { WebSocketStore.load(flowID: flow.id) }.value
                if loaded != messages { messages = loaded }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
