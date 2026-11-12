//
//  FlowFilterSet.swift
//  ProxletCore
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// The flow list's filter rows; rows that are off, empty or an invalid regex don't filter.
public struct FlowFilterSet: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: UUID
        public var enabled: Bool
        public var filter: FlowQuery.Filter

        public init(id: UUID = UUID(), enabled: Bool = true, filter: FlowQuery.Filter = FlowQuery.Filter(key: "url", value: "")) {
            self.id = id
            self.enabled = enabled
            self.filter = filter
        }
    }

    public var rows: [Row]
    /// true: every active row must match (AND); false: any of them (OR).
    public var matchAll = true

    public init(rows: [Row] = [Row()], matchAll: Bool = true) {
        self.rows = rows.isEmpty ? [Row()] : rows
        self.matchAll = matchAll
    }

    /// Rows that actually filter: switched on, with text, and a regex that compiles.
    public var activeFilters: [FlowQuery.Filter] {
        rows.filter { row in
            row.enabled && !row.filter.value.isEmpty && (row.filter.matching != "regex" || FlowQuery.isValidRegex(row.filter.value))
        }
        .map(\.filter)
    }

    /// Computes the active rows once, for filtering a whole list; regex rows are compiled once here, not per flow.
    public func matcher() -> (Flow) -> Bool {
        let tests: [(Flow) -> Bool] = activeFilters.map { filter in
            guard filter.matching == "regex",
                  let regex = try? NSRegularExpression(pattern: filter.value, options: filter.caseSensitive ? [] : .caseInsensitive)
            else { return { FlowQuery.matches($0, filter) } }
            return { flow in
                let text = FlowQuery.value(of: filter.key, in: flow)
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
        guard !tests.isEmpty else { return { _ in true } }
        return matchAll ? { flow in tests.allSatisfy { $0(flow) } } : { flow in tests.contains { $0(flow) } }
    }

    /// Inserts a URL row after `id` (or at the end) and returns its id.
    @discardableResult
    public mutating func addRow(after id: UUID?) -> UUID {
        let row = Row()
        if let id, let i = rows.firstIndex(where: { $0.id == id }) { rows.insert(row, at: i + 1) } else { rows.append(row) }
        return row.id
    }

    /// The last row is cleared instead, so the panel always has one.
    public mutating func removeRow(_ id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if rows.count == 1 { rows[0] = Row(id: rows[0].id) } else { rows.remove(at: i) }
    }

    /// Carries the toolbar search into the panel as a URL Contains row: the first empty row, else a new one at the end.
    public mutating func adopt(search text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let row = Row(filter: FlowQuery.Filter(key: "url", value: text))
        if let i = rows.firstIndex(where: { $0.filter.value.isEmpty }) {
            rows[i] = Row(id: rows[i].id, filter: row.filter)
        } else {
            rows.append(row)
        }
    }

    /// Turns every row off, or back on when they are all off.
    public mutating func toggleAll() {
        let on = !rows.contains(where: \.enabled)
        for i in rows.indices { rows[i].enabled = on }
    }
}
