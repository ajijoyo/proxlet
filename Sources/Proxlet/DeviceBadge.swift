//
//  DeviceBadge.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI

/// Client device in a capsule (simulator name, or a network client's IP); click shows its ID with a Copy button.
struct DeviceBadge: View {
    let id: String
    @State private var showsID = false

    var body: some View {
        let isIP = AccessControl.isIP(id)
        let name = isIP ? nil : ProcessLookup.simulatorName(udid: id)
        Button { showsID = true } label: {
            Label(name ?? (isIP ? id : String(id.prefix(8))), systemImage: isIP ? "wifi" : "iphone")
                .font(.caption).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(id)
        .popover(isPresented: $showsID) {
            VStack(alignment: .leading, spacing: 8) {
                Text(name ?? (isIP ? "Network device" : "Unknown simulator")).font(.headline)
                HStack {
                    Text(id).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(id, forType: .string)
                    }
                    .labelStyle(.iconOnly).help("Copy")
                }
            }
            .padding(12)
        }
    }
}
