//
//  DeviceBadge.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the GNU General Public License v3.0.
//

import ProxletCore
import SwiftUI

/// Client devices in one capsule (first name, plus "+N" for the rest); click lists each ID with a Copy button.
struct DeviceBadge: View {
    let ids: [String]
    @State private var showsIDs = false

    private static func name(_ id: String) -> String? {
        AccessControl.isIP(id) ? nil : ProcessLookup.simulatorName(udid: id)
    }

    private static func short(_ id: String) -> String {
        name(id) ?? (AccessControl.isIP(id) ? id : String(id.prefix(8)))
    }

    var body: some View {
        if let first = ids.first {
            let allIP = ids.allSatisfy(AccessControl.isIP)
            Button { showsIDs = true } label: {
                Label(Self.short(first) + (ids.count > 1 ? " +\(ids.count - 1)" : ""), systemImage: allIP ? "wifi" : "iphone")
                    .font(.caption).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(ids.map { id in Self.name(id).map { "\($0) — \(id)" } ?? id }.joined(separator: "\n"))
            .popover(isPresented: $showsIDs) { popover }
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ids.count > 1 { Text("\(ids.count) devices").font(.headline) }
            ForEach(ids, id: \.self) { id in
                VStack(alignment: .leading, spacing: 2) {
                    let isIP = AccessControl.isIP(id)
                    Label(Self.name(id) ?? (isIP ? "Network device" : "Unknown simulator"), systemImage: isIP ? "wifi" : "iphone")
                        .font(ids.count > 1 ? .body : .headline)
                    HStack {
                        Text(id).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(id, forType: .string)
                        }
                        .labelStyle(.iconOnly).help("Copy")
                    }
                }
            }
        }
        .padding(12)
    }
}
