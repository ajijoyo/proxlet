//
//  FlowTable.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AppKit
import ProxletCore
import SwiftUI

/// Flow list on NSTableView: a new batch only redraws the visible rows (SwiftUI `Table` diffed every row).
struct FlowTable: NSViewRepresentable {
    let rows: [Flow]
    @Binding var selection: Set<Flow.ID>
    let urlTitle: String
    let displayURL: (Flow) -> String
    /// Fills the context menu for the clicked rows (the selection when the click is inside it).
    let menu: (Set<Flow.ID>, NSMenu) -> Void
    let onDelete: (Set<Flow.ID>) -> Void

    /// Column id → (title, width), in display order.
    private static let columns: KeyValuePairs<String, (String, CGFloat)> = [
        "method": ("Method", 64), "status": ("Status", 50), "url": ("URL", 520),
        "time": ("Time", 90), "duration": ("Duration", 70), "marks": ("", 40),
    ]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTable()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 24
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for (id, (title, width)) in Self.columns {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            if id == "url" {
                column.minWidth = 200
                column.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                column.resizingMask = .userResizingMask
            }
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.menu = NSMenu()
        table.menu?.delegate = context.coordinator
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FlowTable
        weak var table: KeyTable?
        private var rows: [Flow] = []
        /// Set while Proxlet changes the table itself, so those changes don't write back to the binding.
        private var syncing = false

        init(_ parent: FlowTable) { self.parent = parent }

        func update(_ parent: FlowTable) {
            self.parent = parent
            guard let table else { return }
            table.onDelete = { [weak self] in self.map { $0.parent.onDelete($0.parent.selection) } }
            syncing = true
            defer { syncing = false }
            if let url = table.tableColumns.first(where: { $0.identifier.rawValue == "url" }), url.title != parent.urlTitle {
                url.title = parent.urlTitle
                url.headerCell.attributedStringValue = NSAttributedString(
                    string: parent.urlTitle, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
            }
            if rows != parent.rows {
                let added = parent.rows.count - rows.count
                let prepended = added > 0 && parent.rows[added...].elementsEqual(rows) { $0.id == $1.id }
                rows = parent.rows
                // New flows land on top: insert them so the visible cells stay as they are.
                if prepended { table.insertRows(at: IndexSet(0..<added)) } else { table.reloadData() }
            }
            let wanted = parent.selection.isEmpty ? IndexSet()
                : IndexSet(rows.indices.filter { parent.selection.contains(rows[$0].id) })
            if table.selectedRowIndexes != wanted { table.selectRowIndexes(wanted, byExtendingSelection: false) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, rows.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FlowCell ?? FlowCell(id)
            let flow = rows[row]
            cell.show(flow, url: parent.displayURL(flow))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, rows.indices.contains(table.clickedRow) else { return }
            let clicked = table.clickedRow
            let ids = table.selectedRowIndexes.contains(clicked)
                ? Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
                : [rows[clicked].id]
            parent.menu(ids, menu)
        }
    }
}

/// ⌫ / Edit › Delete delete the selected rows.
final class KeyTable: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map { Int($0.value) }
        if key == NSDeleteCharacter || key == NSDeleteFunctionKey { onDelete?() } else { super.keyDown(with: event) }
    }

    @objc func delete(_ sender: Any?) { onDelete?() }
}

/// One reusable cell per column; the method column draws a pill like `MethodBadge`.
final class FlowCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let pill = Pill()

    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        label.translatesAutoresizingMaskIntoConstraints = false
        label.usesSingleLineMode = true
        label.lineBreakMode = id.rawValue == "url" ? .byTruncatingMiddle : .byTruncatingTail
        if id.rawValue == "method" {
            pill.translatesAutoresizingMaskIntoConstraints = false
            addSubview(pill)
            pill.addSubview(label)
            label.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: leadingAnchor), pill.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 5),
                label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -5),
                label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
                label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
            ])
        } else {
            addSubview(label)
            // Lets the row's selection style recolor plain text (URL, time, duration).
            if id.rawValue != "status" { textField = label }
            label.font = id.rawValue == "status" ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                : id.rawValue == "url" ? .systemFont(ofSize: NSFont.systemFontSize)
                : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor), label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ flow: Flow, url: String) {
        toolTip = nil
        switch identifier?.rawValue {
        case "method":
            let method = flow.websocket ? "WS" : flow.method
            let color = NSColor(HTTPStyle.method(method))
            label.stringValue = method
            label.textColor = color
            pill.color = color
        case "status":
            label.stringValue = "\(flow.status)"
            label.textColor = NSColor(HTTPStyle.status(flow.status))
        case "url":
            label.stringValue = url
            toolTip = flow.url
        case "time":
            label.stringValue = FlowListView.time.string(from: flow.startedAt)
        case "duration":
            label.stringValue = "\(flow.durationMs) ms"
        default:
            let marks = NSMutableAttributedString()
            var tips: [String] = []
            func add(_ symbol: String, _ tip: String) {
                let image = NSTextAttachment()
                image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
                marks.append(NSAttributedString(attachment: image))
                marks.append(NSAttributedString(string: " "))
                tips.append(tip)
            }
            if flow.mocked { add("wand.and.stars", "Served by Map Local") }
            if !flow.scripts.isEmpty { add("curlybraces", "Changed by script: \(flow.scripts.joined(separator: ", "))") }
            label.attributedStringValue = marks
            toolTip = tips.isEmpty ? nil : tips.joined(separator: "\n")
        }
    }
}

/// Tinted rounded background, re-resolved when the appearance changes.
final class Pill: NSView {
    var color = NSColor.clear { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = color.withAlphaComponent(0.15).cgColor
        layer?.cornerRadius = 4
    }
}

/// Context-menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
