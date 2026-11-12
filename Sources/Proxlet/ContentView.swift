//
//  ContentView.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .all

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            Group {
                switch selection {
                case .mapLocal: MapLocalView()
                case .scripts: ScriptsView()
                default: FlowListView(filter: selection ?? .all)
                }
            }
            // Status bar spans the detail column only, so it starts after the sidebar.
            .safeAreaInset(edge: .bottom) { statusBar }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.recording.toggle() } label: {
                    Label(model.recording ? "Pause" : "Play",
                          systemImage: model.recording ? "pause.fill" : "play.fill")
                }
                .help(model.recording ? "Pause recording (traffic keeps flowing)" : "Resume recording")
                Button(action: model.toggleSystemProxy) {
                    Label(model.systemProxyOn ? "System Proxy On" : "System Proxy Off",
                          systemImage: model.systemProxyOn ? "network" : "network.slash")
                }
                Button {
                    if model.confirm("Delete all \(model.flows.count) flows?",
                                     "Their requests, responses and WebSocket messages will be deleted. This can't be undone.") {
                        model.clearFlows()
                    }
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(!model.running ? Color.secondary : model.recording ? Color.green : Color.orange).frame(width: 8, height: 8)
            if model.running {
                Text("Listening on \(model.lanIP ?? "127.0.0.1"):\(String(model.port))")
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .help("Use this host and port as the HTTP proxy on a phone in the same Wi-Fi. 127.0.0.1:\(String(model.port)) works on this Mac.")
            } else {
                Text("Not running").fontWeight(.semibold)
            }
            Text(model.recording ? "Recording" : "Paused")
            Divider().frame(height: 12)
            StatusPill(title: "System Proxy", on: model.systemProxyOn)
            StatusPill(title: "Map Local", on: model.mapLocalOn)
            StatusPill(title: "Scripts", on: model.scriptsOn)
            StatusPill(title: "No Caching", on: model.noCachingOn)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
