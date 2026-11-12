//
//  FlowListView.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI

struct FlowListView: View {
    @Environment(AppModel.self) private var model
    let filter: SidebarItem
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var selection = Set<Flow.ID>()
    @State private var split: CGFloat = 0.5
    @FocusState private var focusedRow: UUID?

    private var filtered: [Flow] {
        var all = model.flows.reversed().filter(filter.matches)
        if model.filterPanelShown {
            let match = model.appliedFilter.matcher()
            all = all.filter(match)
        }
        guard !search.isEmpty else { return all }
        return all.filter { $0.url.localizedCaseInsensitiveContains(search) || $0.method.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        @Bindable var model = model
        let rows = filtered
        VStack(spacing: 0) {
            if model.filterPanelShown {
                FlowFilterPanel(draft: $model.filterDraft, focus: $focusedRow, applied: model.appliedFilter, apply: model.applyFilter)
                Divider()
            }
            list(rows)
        }
        .background { shortcuts }
        .toolbar {
            // Its own toolbar group, apart from Record / System Proxy / Clear (macOS 26 merges adjacent items), whichever side it lands on.
            if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
            // One filter at a time: the quick search sits next to the Filter button and hides while the panel is open.
            ToolbarItemGroup {
                if !model.filterPanelShown { searchField }
                Button { togglePanel() } label: {
                    // Filled while the panel is open, so filter mode is visible at a glance.
                    Label("Filter", systemImage: model.filterPanelShown ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help("Filter rows (⌘F)")
            }
            if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter URL or method", text: $search)
                .textFieldStyle(.plain)
                .onExitCommand { search = "" }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear Search")
            }
        }
        // No fill of its own: the toolbar group behind it is the field's background.
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 240)
    }

    /// Hidden buttons so the panel's shortcuts work wherever focus is in the flow list.
    @ViewBuilder
    private var shortcuts: some View {
        Group {
            Button("") { togglePanel() }.keyboardShortcut("f", modifiers: .command)
            if model.filterPanelShown {
                Button("") { focusedRow = model.filterDraft.addRow(after: focusedRow) }.keyboardShortcut("n", modifiers: .command)
                Button("") { moveFocus(by: -1) }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("") { moveFocus(by: 1) }.keyboardShortcut(.downArrow, modifiers: .command)
                Button("") {
                    model.filterDraft.toggleAll()
                    model.applyFilter()
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("") { model.filterPanelShown = false }.keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Opening moves any quick-search text into the panel (applied at once), so the list doesn't change under the user.
    private func togglePanel() {
        model.filterPanelShown.toggle()
        guard model.filterPanelShown else { return }
        if !search.isEmpty {
            model.filterDraft.adopt(search: search)
            model.applyFilter()
            search = ""
        }
        focusedRow = model.filterDraft.rows.first?.id
    }

    /// With no row focused, down goes to the first row and up to the last.
    private func moveFocus(by step: Int) {
        let ids = model.filterDraft.rows.map(\.id)
        guard !ids.isEmpty else { return }
        if let current = focusedRow, let i = ids.firstIndex(of: current) {
            focusedRow = ids[min(max(i + step, 0), ids.count - 1)]
        } else {
            focusedRow = step > 0 ? ids.first : ids.last
        }
    }

    private func list(_ rows: [Flow]) -> some View {
        // Detail is shown for a single selection; multi-select is for batch actions.
        let detail = selection.count == 1 ? selection.first.flatMap { model.index.byID[$0] } : nil
        // One split either way, so the table (and its scroll position) survives opening a flow.
        return ResizableSplit(axis: .vertical, fraction: $split, minFirst: 120, minSecond: 200, showsSecond: detail != nil) {
            table(rows)
        } second: {
            if let detail { FlowDetailView(flow: detail) }
        }
        // Opening a flow from the empty state always starts at half height.
        .onChange(of: selection) { old, new in
            if old.count != 1, new.count == 1 { split = 0.5 }
        }
    }

    private func table(_ rows: [Flow]) -> some View {
        FlowTable(rows: rows, selection: $selection, urlTitle: filter.urlTitle, displayURL: filter.displayURL,
                  menu: menu, onDelete: delete)
    }

    private func menu(_ ids: Set<Flow.ID>, _ menu: NSMenu) {
        if ids.count == 1, let id = ids.first, let flow = model.index.byID[id], flow.method == "CONNECT" {
            menu.addItem(MenuAction("Enable SSL Proxying for \(flow.host)", symbol: "lock.open") { model.setSSLProxying(true, for: flow.host) })
            menu.addItem(.separator())
        } else if ids.count == 1, let id = ids.first, let flow = model.index.byID[id] {
            menu.addItem(MenuAction("Map Local", symbol: "wand.and.stars") {
                if let id = model.mock(flow) { openWindow(id: "mapLocal", value: id) }
            })
            menu.addItem(MenuAction("Add Script", symbol: "curlybraces") {
                if let name = model.addScript(for: flow.url, method: flow.method) { openWindow(id: "script", value: name) }
            })
            menu.addItem(MenuAction("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(flow.url, forType: .string)
            })
            menu.addItem(MenuAction("Export Response…", symbol: "doc.badge.arrow.up") { SessionFiles.exportResponse(flow, model: model) })
            menu.addItem(.separator())
        }
        if !ids.isEmpty {
            menu.addItem(MenuAction(ids.count == 1 ? "Delete" : "Delete \(ids.count) Flows", symbol: "trash") { delete(ids) })
        }
    }

    private func delete(_ ids: Set<Flow.ID>) {
        guard !ids.isEmpty else { return }
        let title = ids.count == 1 ? "Delete this flow?" : "Delete \(ids.count) flows?"
        guard model.confirm(title, "Their requests, responses and WebSocket messages will be deleted. This can't be undone.") else { return }
        model.deleteFlows(ids)
        selection.subtract(ids)
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
