//
//  DeviceTargetSection.swift
//  Proxlet
//
//  Created by Aji on 15/11/26
//  Copyright © 2026 Aji. Licensed under the GNU General Public License v3.0.
//

import ProxletCore
import SwiftUI

struct DeviceTargetSection: View {
    @Binding var specific: Bool
    @Binding var text: String

    static func targets(specific: Bool, text: String) throws -> [String]? {
        guard specific else { return nil }
        let ids = text.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",")))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw TargetError() }
        return try MockRule.devices(ids)
    }

    private struct TargetError: LocalizedError {
        var errorDescription: String? { "Enter at least one simulator UUID or device IP address." }
    }

    var body: some View {
        GroupBox("Devices") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Scope", selection: $specific) {
                    Text("Global").tag(false)
                    Text("Specific Devices").tag(true)
                }
                .pickerStyle(.segmented)
                if specific {
                    TextField("Simulator UUID or device IP, separated by commas", text: $text)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Text("Applies to all clients matching this rule.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }
}
