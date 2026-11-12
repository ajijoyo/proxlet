//
//  AppModel.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import AppKit
import Observation
import ProxletCore
import SwiftUI

@MainActor
@Observable
final class AppModel {
    static let portKey = "port"
    static var storedPort: Int { UserDefaults.standard.object(forKey: portKey) as? Int ?? SharedState.defaultPort }

    /// Proxy port; editable in Settings. Fixed by the user, never moved automatically (devices are configured with it).
    var port = AppModel.storedPort
    var flows: [Flow] = [] { didSet { index = FlowIndex(flows) } }
    private(set) var index = FlowIndex()
    var rules: [MockRule] = []
    var scripts: [String] = []
    /// Parsed `// @…` header per script file (name, enabled, match).
    var scriptMeta: [String: ScriptMeta] = [:]
    /// Lifetime of the next generated CA; the current CA keeps its own dates until it is regenerated.
    var caValidityDays = UserDefaults.standard.object(forKey: "caValidityDays") as? Int ?? CertificateAuthority.defaultValidityDays {
        didSet {
            let range = CertificateAuthority.validityRange
            let days = min(max(caValidityDays, range.lowerBound), range.upperBound)
            if days != caValidityDays { caValidityDays = days }
            UserDefaults.standard.set(days, forKey: "caValidityDays")
        }
    }
    var caExpiry: Date?
    /// ssl-proxying.json; proxlet-mcp may edit it, so the refresh timer re-reads it.
    var sslProxying = SSLProxying.load()
    var running = false {
        didSet { if oldValue != running { publish { [running] in $0.running = running } } }
    }
    var recording = SharedState.load().recording {
        didSet {
            store.isRecording = recording
            if oldValue != recording { publish { [recording] in $0.recording = recording } }
        }
    }
    var systemProxyOn = false
    var lanIP = SystemProxy.lanIPv4()
    var pinnedHosts: [String] = UserDefaults.standard.stringArray(forKey: "pinnedHosts") ?? [] {
        didSet { UserDefaults.standard.set(pinnedHosts, forKey: "pinnedHosts") }
    }
    // Master switches live in state.json so proxlet-mcp can flip them too.
    var mapLocalOn = SharedState.load().mapLocal {
        didSet {
            pipeline.mapLocalEnabled = mapLocalOn
            if oldValue != mapLocalOn { publish { [mapLocalOn] in $0.mapLocal = mapLocalOn } }
        }
    }
    var scriptsOn = SharedState.load().scripts {
        didSet {
            pipeline.scriptsEnabled = scriptsOn
            if oldValue != scriptsOn { publish { [scriptsOn] in $0.scripts = scriptsOn } }
        }
    }
    var noCachingOn = SharedState.load().noCaching {
        didSet {
            pipeline.noCachingEnabled = noCachingOn
            if oldValue != noCachingOn { publish { [noCachingOn] in $0.noCaching = noCachingOn } }
        }
    }
    // Flow filter panel: edits go to the draft and reach the list on Apply; kept for the session only.
    var filterDraft = FlowFilterSet()
    var appliedFilter = FlowFilterSet()
    var filterPanelShown = false
    @ObservationIgnored private var lastClear = SharedState.load().clearedAt

    let store = FlowStore()
    let access = AccessControl()
    private let pipeline: FlowPipeline
    private var server: ProxyServer?
    @ObservationIgnored var pending: [Flow] = []
    @ObservationIgnored private var flushScheduled = false

    private func enqueue(_ flow: Flow) {
        pending.append(flow)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(flows.count > 2000 ? 1000 : 300))
            flows.append(contentsOf: pending)
            pending.removeAll()
            flushScheduled = false
        }
    }

    /// `startProxy: false` (tests) skips the listener, the refresh timer and connection prompts.
    init(startProxy: Bool = true) {
        pipeline = FlowPipeline(store: store)
        pipeline.mapLocalEnabled = mapLocalOn
        pipeline.scriptsEnabled = scriptsOn
        pipeline.noCachingEnabled = noCachingOn
        store.isRecording = recording
        flows = FlowStore.load()
        _ = Theme.current  // creates theme.json on first launch so it can be edited
        // Flows arrive from many connections at once; publish them in batches (UI re-renders ~3x/s, 1x/s past 2000 flows).
        store.onAppend = { [weak self] flow in
            Task { @MainActor in self?.enqueue(flow) }
        }
        systemProxyOn = SystemProxy.isEnabled(port: port)
        reloadRules()
        guard startProxy else { return }
        access.ask = { [weak self] ip in await self?.askAccess(ip) ?? false }
        // Rules and scripts may be edited by proxlet-mcp or a text editor.
        _ = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Task { await start() }
    }

    /// One tick of the refresh timer: picks up edits made outside the app.
    func refresh() {
        reloadRules()
        refreshSystemProxy()
        let ip = SystemProxy.lanIPv4()
        if lanIP != ip { lanIP = ip }
        applySharedState()
        let ssl = SSLProxying.load()
        if sslProxying != ssl { sslProxying = ssl }
    }

    func start() async {
        do {
            let ca = try CertificateAuthority.loadOrCreate(validityDays: caValidityDays)
            caExpiry = ca.certificate.notValidAfter
            let server = ProxyServer(port: port, ca: ca, pipeline: pipeline, access: access)
            try await server.start()
            self.server = server
            running = true
        } catch {
            running = false
            let owner = ProcessLookup.listener(port: port).map { " It is used by \($0)." } ?? ""
            alert("Proxlet could not listen on port \(port).\(owner) Choose another port in Settings (⌘,).\n\n\(error)")
        }
    }

    /// Restarts the proxy on `newPort` and re-points the system proxy if it was on.
    func changePort(_ newPort: Int) async {
        guard newPort != port, (1024...65535).contains(newPort) else { return }
        // Read before the awaits: the refresh timer checks the new port and would report the proxy as off.
        let wasOn = systemProxyOn
        await server?.stop()
        server = nil
        running = false
        port = newPort
        UserDefaults.standard.set(newPort, forKey: Self.portKey)
        await start()
        if running, wasOn {
            let p = newPort
            Task.detached {
                do { try SystemProxy.setEnabled(true, port: p) } catch {
                    await MainActor.run { self.alert("System proxy failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    /// Replaces the CA with a new one valid `caValidityDays`; every device must install it again.
    func regenerateCA() async {
        guard confirm("Delete the current CA and create a new one?",
                      "HTTPS stops working on this Mac, simulators and devices until the new CA is installed and trusted there.") else { return }
        await server?.stop()
        server = nil
        running = false
        do { try CertificateAuthority.remove() } catch {
            alert("Could not delete the CA: \(error.localizedDescription)")
        }
        await start()
        guard running else { return }
        showNewCASteps()
    }

    /// Replaced in tests; the defaults show modal alerts.
    @ObservationIgnored var confirmHandler: (String, String) -> Bool = AppModel.confirmAlert
    @ObservationIgnored var alertHandler: (String) -> Void = AppModel.warningAlert

    /// Asks before a destructive action; returns true when confirmed.
    func confirm(_ title: String, _ detail: String) -> Bool { confirmHandler(title, detail) }

    /// Shows a failure; success needs no message.
    func alert(_ text: String) { alertHandler(text) }

    private static func confirmAlert(_ title: String, _ detail: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = detail
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    private static func warningAlert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Proxlet"
        a.informativeText = text
        a.alertStyle = .warning
        a.runModal()
    }

    /// Writes one change to state.json. Only the changed field is written, so a concurrent MCP edit to another switch survives.
    private func publish(_ change: (inout SharedState) -> Void) {
        SharedState.update(change)
    }

    /// Applies changes made by proxlet-mcp (toggle_recording, toggle_tool, clear_session).
    private func applySharedState() {
        let state = SharedState.load()
        if state.recording != recording { recording = state.recording }
        if state.mapLocal != mapLocalOn { mapLocalOn = state.mapLocal }
        if state.scripts != scriptsOn { scriptsOn = state.scripts }
        if state.noCaching != noCachingOn { noCachingOn = state.noCaching }
        if state.clearedAt != lastClear {
            lastClear = state.clearedAt
            // Flows captured after the clear are still in flows.jsonl; keep them.
            if let cleared = state.clearedAt {
                pending = Self.keep(pending, after: cleared)
                flows = Self.keep(flows, after: cleared)
            }
        }
        if state.port != port || state.lanIP != lanIP || state.running != running {
            publish { [port, lanIP, running] in
                $0.port = port
                $0.lanIP = lanIP
                $0.running = running
            }
        }
    }

    func applyFilter() { appliedFilter = filterDraft }

    nonisolated static func keep(_ flows: [Flow], after cleared: Date) -> [Flow] {
        flows.filter { $0.startedAt > cleared }
    }

    func togglePin(_ host: String) {
        if let i = pinnedHosts.firstIndex(of: host) { pinnedHosts.remove(at: i) } else { pinnedHosts.append(host) }
    }

    func toggleSystemProxy() {
        let target = !systemProxyOn
        Task.detached { [port] in
            do {
                try SystemProxy.setEnabled(target, port: port)
                await MainActor.run { self.systemProxyOn = target }
            } catch {
                await MainActor.run { self.alert("System proxy failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Picks up proxy changes made outside the app (System Settings, networksetup).
    func refreshSystemProxy() {
        Task.detached { [port] in
            let on = SystemProxy.isEnabled(port: port)
            await MainActor.run { if self.systemProxyOn != on { self.systemProxyOn = on } }
        }
    }

    func runTask(_ label: String, _ work: @escaping @Sendable () throws -> Void) {
        Task.detached {
            do {
                try work()
            } catch {
                await MainActor.run { self.alert("\(label) failed: \(error.localizedDescription)") }
            }
        }
    }
}
