//
//  SidebarView.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import ProxletCore
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case mapLocal
    case scripts
    /// Client app guessed from User-Agent.
    case app(String)
    /// Pinned host pattern, `*` is a wildcard (e.g. `*.acme.test`).
    case hostPattern(String)
    case host(String)
    /// Path prefix within a host, e.g. `/api/v1`.
    case path(host: String, path: String)
    /// Same item shown in another sidebar section (e.g. under Pinned) so each row has a unique tag.
    indirect case scoped(String, SidebarItem)

    var base: SidebarItem {
        if case .scoped(_, let item) = self { return item.base }
        return self
    }

    /// Tag for a row in `section`; rows in Domains keep the plain value.
    static func tag(_ item: SidebarItem, section: String) -> SidebarItem {
        section == "domains" ? item : .scoped(section, item)
    }

    func matches(_ flow: Flow) -> Bool {
        switch base {
        case .all, .mapLocal, .scripts, .scoped: true
        case .app(let a): flow.app == a
        case .hostPattern(let p): MockRule.glob(p, matches: flow.host)
        case .host(let h): flow.host == h
        case .path(let h, let p): flow.host == h && (flow.pathOnly == p || flow.pathOnly.hasPrefix(p + "/"))
        }
    }
}

extension SidebarItem {
    /// URL column title: "URL" for All, otherwise the selected scope, e.g. `web.acme.test/*`.
    var urlTitle: String {
        switch base {
        case .host(let h): "\(h)/*"
        case .path(let h, let p): "\(h)\(p)/*"
        case .hostPattern(let p): "\(p)/*"
        default: "URL"
        }
    }

    /// URL shortened relative to the scope; copy actions still use the full `flow.url`.
    func displayURL(_ flow: Flow) -> String {
        switch base {
        case .host: "*" + flow.path
        case .path(_, let p): "*" + flow.path.dropFirst(p.count)
        case .hostPattern: flow.host + flow.path
        default: flow.url
        }
    }
}

/// One path segment in a host's tree; `id` is the full prefix (`/api/v1`).
struct PathNode: Identifiable {
    /// Unique in the whole sidebar List (host + path, then section via `scoped`); rows sharing an id overlap.
    var id: String
    /// e.g. `/api/v1`
    let path: String
    let name: String
    let count: Int
    let sampleURL: String
    var children: [PathNode]
    /// The same tree shown in another sidebar section needs its own ids.
    func scoped(_ section: String) -> PathNode {
        var copy = self
        copy.id = section + "|" + id
        copy.children = children.map { $0.scoped(section) }
        return copy
    }

    /// nil for leaves, so `OutlineGroup` draws no disclosure triangle.
    var outlineChildren: [PathNode]? { children.isEmpty ? nil : children }

    static func tree(host: String, scheme: String, flows: [Flow], prefix: String = "", depth: Int = 0) -> [PathNode] {
        Dictionary(grouping: flows) { f in depth < f.pathSegments.count ? String(f.pathSegments[depth]) : "" }
            .filter { !$0.key.isEmpty }
            .sorted { $0.key < $1.key }
            .map { segment, group in
                let path = prefix + "/" + segment
                let deeper = group.filter { $0.pathSegments.count > depth + 1 }
                return PathNode(
                    id: host + path, path: path, name: segment, count: group.count, sampleURL: "\(scheme)://\(host)\(path)",
                    children: deeper.isEmpty ? [] : tree(host: host, scheme: scheme, flows: deeper, prefix: path, depth: depth + 1)
                )
            }
    }
}

/// A sidebar string (host, app, pin) with an id unique across sections; one List must never repeat an id.
struct Keyed: Identifiable {
    let id: String
    let value: String

    static func list(_ values: [String], in section: String) -> [Keyed] {
        values.map { Keyed(id: section + "|" + $0, value: $0) }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var expanded: Set<String> = []
    @State private var showAddPin = false
    @AppStorage("sidebar.pinnedOpen") private var pinnedOpen = true
    @AppStorage("sidebar.domainsOpen") private var domainsOpen = true
    @AppStorage("sidebar.allOpen") private var allOpen = true
    @AppStorage("sidebar.appsOpen") private var appsOpen = false
    @State private var newPin = ""
    @State private var hostFilter = ""
    @FocusState private var filterFocused: Bool

    /// Hosts containing `query` (case-insensitive); everything when it is blank.
    static func filter(_ hosts: [String], _ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? hosts : hosts.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        let index = model.index
        let byHost = index.byHost, byApp = index.byApp, apps = index.apps
        let hosts = Self.filter(index.hosts, hostFilter)
        let filtering = !hostFilter.trimmingCharacters(in: .whitespaces).isEmpty
        // A filter shows its matches even in sections the user had collapsed.
        let domainsShown = filtering ? .constant(true) : $domainsOpen

        List(selection: $selection) {
            Label("All", systemImage: "tray.full").badge(model.flows.count).tag(SidebarItem.all)
            Label("Map Local", systemImage: "wand.and.stars").badge(model.rules.count).tag(SidebarItem.mapLocal)
            Label("Scripts", systemImage: "curlybraces").badge(model.scripts.count).tag(SidebarItem.scripts)

            // Plain sections with our own header: the chevron is always visible and the whole title toggles.
            Section {
                if pinnedOpen {
                    ForEach(Keyed.list(model.pinnedHosts, in: "pinned")) { item in
                        let pin = item.value
                        if pin.contains("*") {
                            let matched = hosts.filter { MockRule.glob(pin, matches: $0) }
                            if !filtering || !matched.isEmpty { patternRow(pin, hosts: matched, byHost: byHost) }
                        } else if !filtering || !Self.filter([pin], hostFilter).isEmpty {
                            hostRow(pin, flows: byHost[pin] ?? [], section: "pinned", icon: "pin.fill")
                        }
                    }
                }
            } header: {
                CollapsibleHeader(title: "Pinned", isExpanded: $pinnedOpen)
            }

            Section {
                if allOpen {
                    DisclosureGroup(isExpanded: $appsOpen) {
                        ForEach(Keyed.list(apps, in: "apps")) { item in
                            let app = item.value
                            Label(app, systemImage: Self.icon(forApp: app))
                                .badge(byApp[app]?.count ?? 0)
                                .contextMenu {
                                    Button("Delete \(app) Flows", systemImage: "trash", role: .destructive) {
                                        model.confirmDeleteFlows(byApp[app] ?? [], from: app)
                                    }
                                }
                                .tag(SidebarItem.app(app))
                        }
                    } label: {
                        Label("Apps", systemImage: "square.stack.3d.up").badge(apps.count)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation { appsOpen.toggle() } }
                    }
                    DisclosureGroup(isExpanded: domainsShown) {
                        ForEach(Keyed.list(hosts, in: "domains")) { item in
                            hostRow(item.value, flows: byHost[item.value] ?? [], section: "domains", icon: "globe")
                        }
                    } label: {
                        Label("Domains", systemImage: "globe").badge(hosts.count)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation { domainsOpen.toggle() } }
                    }
                    if filtering && hosts.isEmpty {
                        Text("No hosts match \"\(hostFilter)\"").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                CollapsibleHeader(title: "All", isExpanded: $allOpen)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { filterBar }
        .sheet(isPresented: $showAddPin) { addPinSheet }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Button { showAddPin = true } label: {
                Image(systemName: "plus").frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add Pin")
            .help("Pin a host or pattern like *.example.com")
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter (⌘⇧F)", text: $hostFilter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onExitCommand { hostFilter = "" }
                if !hostFilter.isEmpty {
                    Button { hostFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear Filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .overlay(Capsule().stroke(filterFocused ? Color.accentColor : .clear, lineWidth: 2))
            // ⌘⇧F focuses the filter from anywhere in the window.
            Button("") { filterFocused = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func isExpanded(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { if $0 { expanded.insert(key) } else { expanded.remove(key) } }
        )
    }

    private func patternRow(_ pattern: String, hosts: [String], byHost: [String: [Flow]]) -> some View {
        DisclosureGroup(isExpanded: isExpanded("pattern:\(pattern)")) {
            ForEach(Keyed.list(hosts, in: "pattern:\(pattern)")) { item in
                hostRow(item.value, flows: byHost[item.value] ?? [], section: "pattern:\(pattern)", icon: "globe")
            }
        } label: {
            Label(pattern, systemImage: "pin.fill")
                .badge(hosts.reduce(0) { $0 + (byHost[$1]?.count ?? 0) })
                .contextMenu { unpinButton(pattern) }
        }
        .tag(SidebarItem.tag(.hostPattern(pattern), section: "pinned"))
    }

    private func hostRow(_ host: String, flows: [Flow], section: String, icon: String) -> some View {
        let key = "\(section):\(host)"
        let isPinned = model.pinnedHosts.contains(host)
        return DisclosureGroup(isExpanded: isExpanded(key)) {
            // Native outline items keep row identity stable when flows arrive or rows expand.
            OutlineGroup((model.index.trees[host] ?? []).map { $0.scoped(section) }, children: \.outlineChildren) { node in
                PathRow(host: host, node: node).tag(SidebarItem.tag(.path(host: host, path: node.path), section: section))
            }
        } label: {
            Label(host, systemImage: icon)
                .badge(flows.count)
                .contextMenu {
                    if isPinned {
                        unpinButton(host)
                    } else {
                        Button("Pin to Top", systemImage: "pin") { model.togglePin(host) }
                    }
                    if let wildcard = Self.wildcard(for: host), !model.pinnedHosts.contains(wildcard) {
                        Button("Pin \(wildcard)", systemImage: "pin") { model.togglePin(wildcard) }
                    }
                    Divider()
                    if model.sslProxying.shouldDecrypt(host) {
                        Button("Disable SSL Proxying", systemImage: "lock") { model.setSSLProxying(false, for: host) }
                    } else {
                        Button("Enable SSL Proxying", systemImage: "lock.open") { model.setSSLProxying(true, for: host) }
                        if let wildcard = Self.wildcard(for: host) {
                            Button("Enable SSL Proxying for \(wildcard)", systemImage: "lock.open") { model.setSSLProxying(true, for: wildcard) }
                        }
                    }
                    Divider()
                    Button("Delete \(host) Flows", systemImage: "trash", role: .destructive) { model.confirmDeleteFlows(flows, from: host) }
                }
        }
        .tag(SidebarItem.tag(.host(host), section: section))
    }

    private func unpinButton(_ pin: String) -> some View {
        Button("Unpin", systemImage: "pin.slash") { model.togglePin(pin) }
    }

    static func icon(forApp app: String) -> String {
        switch app {
        case "Safari", "Chrome", "Firefox", "Edge", "Browser": "safari"
        case "Unknown": "questionmark.app"
        default: "app"
        }
    }

    /// `api.acme.test` → `*.acme.test`; nil for two-label hosts and IPs.
    static func wildcard(for host: String) -> String? {
        let labels = host.split(separator: ".")
        guard labels.count > 2, !host.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return "*." + labels.dropFirst().joined(separator: ".")
    }

    private var addPinSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Pin").font(.headline)
            TextField("api.example.com or *.example.com", text: $newPin)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(addPin)
            Text("Use * as a wildcard. *.example.com groups every subdomain.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showAddPin = false }.keyboardShortcut(.cancelAction)
                Button("Pin", action: addPin).keyboardShortcut(.defaultAction)
                    .disabled(newPin.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func addPin() {
        let pin = newPin.trimmingCharacters(in: .whitespaces).lowercased()
        if !pin.isEmpty, !model.pinnedHosts.contains(pin) { model.togglePin(pin) }
        newPin = ""
        showAddPin = false
    }
}

/// Section title with an always-visible chevron; clicking anywhere on it collapses or expands the section.
struct CollapsibleHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(title)")
    }
}

/// Recursive path-segment row; selecting it filters to that path prefix.
struct PathRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let host: String
    let node: PathNode

    var body: some View {
        Text(node.name)
            .lineLimit(1)
            .truncationMode(.middle)
            .badge(node.count)
            .contextMenu {
                Button("Map Local", systemImage: "wand.and.stars") {
                    if let id = model.mock(host: host, path: node.path, sampleURL: node.sampleURL) { openWindow(id: "mapLocal", value: id) }
                }
                Button("Add Script", systemImage: "curlybraces") {
                    if let name = model.addScript(for: node.sampleURL) { openWindow(id: "script", value: name) }
                }
                Divider()
                Button("Delete Flows", systemImage: "trash", role: .destructive) {
                    let scope = SidebarItem.path(host: host, path: node.path)
                    model.confirmDeleteFlows((model.index.byHost[host] ?? []).filter(scope.matches), from: host + node.path)
                }
            }
    }
}
