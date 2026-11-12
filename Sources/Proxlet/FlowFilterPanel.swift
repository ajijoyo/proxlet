//
//  FlowFilterPanel.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI

/// Filter rows above the flow list; the list follows `applied`, which `apply` copies from the edited draft.
struct FlowFilterPanel: View {
    @Binding var draft: FlowFilterSet
    var focus: FocusState<UUID?>.Binding
    let applied: FlowFilterSet
    let apply: () -> Void

    static let keyLabels: [String: String] = [
        "url": "URL", "queryString": "Query String", "host": "Host", "method": "Method", "statusCode": "Status Code",
        "requestHeader": "Request Header", "responseHeader": "Response Header", "requestBody": "Request Body",
        "responseBody": "Response Body", "device": "Device (UDID or IP)",
    ]
    static let matchingLabels: [String: String] = [
        "contains": "Contains", "notContains": "Not Contains", "startWith": "Starts With", "endWith": "Ends With",
        "equal": "Equal", "notEqual": "Not Equal", "regex": "Regex", "wildcard": "Wildcard",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($draft.rows) { $row in
                rowView($row)
            }
            HStack(spacing: 12) {
                Picker("", selection: $draft.matchAll) {
                    Text("AND all filters").tag(true)
                    Text("OR any filter").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                Text("Show: ⌘F   New: ⌘N   Up: ⌘↑   Down: ⌘↓   On/Off: ⌘B   Hide: Esc")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if draft != applied {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Unapplied changes")
                }
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == applied)
            }
        }
        .padding(10)
        .background(.bar)
    }

    private func rowView(_ row: Binding<FlowFilterSet.Row>) -> some View {
        let filter = row.wrappedValue.filter
        let badRegex = filter.matching == "regex" && !filter.value.isEmpty && !FlowQuery.isValidRegex(filter.value)
        return HStack(spacing: 8) {
            Toggle("", isOn: row.enabled).labelsHidden().toggleStyle(.checkbox)
            Picker("", selection: row.filter.key) {
                ForEach(FlowQuery.keys, id: \.self) { Text(Self.keyLabels[$0] ?? $0).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            Picker("", selection: row.filter.matching) {
                ForEach(FlowQuery.matchings, id: \.self) { Text(Self.matchingLabels[$0] ?? $0).tag($0) }
            }
            .labelsHidden().frame(width: 130)
            TextField("Text", text: row.filter.value)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: row.wrappedValue.id)
                .onSubmit(apply)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(badRegex ? Color.red : .clear))
                .help(badRegex ? "Invalid regular expression: this row is ignored." : "")
            Button { draft.removeRow(row.wrappedValue.id) } label: { squareIcon("minus") }
                .buttonStyle(.bordered).accessibilityLabel("Remove Filter")
            Button {
                focus.wrappedValue = draft.addRow(after: row.wrappedValue.id)
            } label: { squareIcon("plus") }
                .buttonStyle(.bordered).accessibilityLabel("Add Filter")
        }
    }

    /// Same-size square buttons whose whole box is clickable.
    private func squareIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
    }
}
