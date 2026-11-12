//
//  AppModel+Rules.swift
//  Proxlet
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import ProxletCore

/// Flow, Map Local and script edits driven from the UI.
extension AppModel {
    /// Adds imported flows (and their WebSocket messages) to the log, even while paused.
    /// The store's `onAppend` publishes them to `flows`, so they are not appended here as well.
    func addImported(_ items: [SessionArchive.Imported]) {
        Task.detached { [store] in
            for item in items {
                store.append(item.flow, force: true)
                for m in item.messages { WebSocketStore.append(m, flowID: item.flow.id) }
            }
        }
    }

    func deleteFlows(_ ids: Set<Flow.ID>) {
        guard !ids.isEmpty else { return }
        flows.removeAll { ids.contains($0.id) }
        pending.removeAll { ids.contains($0.id) }
        // Rewriting flows.jsonl can take a moment on a large log; keep it off the main thread.
        Task.detached { [store] in
            store.delete(ids: ids)
            WebSocketStore.delete(flowIDs: ids)
            BodyStore.delete(flowIDs: ids)
        }
    }

    func clearFlows() {
        let ids = Set(flows.map(\.id))
        store.clear()
        Task.detached {
            WebSocketStore.delete(flowIDs: ids)
            BodyStore.delete(flowIDs: ids)
        }
        pending.removeAll()
        flows.removeAll()
    }

    func reloadRules() {
        let loaded = RuleStore.load()
        if loaded != rules { rules = loaded }
        let listed = ScriptStore.list()
        let names = listed.map(\.fileName)
        if names != scripts { scripts = names }
        let metas = Dictionary(uniqueKeysWithValues: listed.map { ($0.fileName, $0.meta) })
        if metas != scriptMeta { scriptMeta = metas }
    }

    /// Creates a Map Local rule from a flow; returns its id for the editor.
    @discardableResult
    func mock(_ flow: Flow) -> String? {
        guard flow.method != "CONNECT" else {
            alert("\(flow.host) isn't decrypted, so there is no response to copy. Enable SSL Proxying for it, then reload.")
            return nil
        }
        do {
            guard let rule = try MockRule.from(flow: flow) else {
                alert("Only a placeholder was recorded for this response (binary that isn't an image, an image over 10 MB, "
                      + "or text over 1 MB). Create the rule with \"New\" in Map Local and choose the body file instead.")
                return nil
            }
            return saveRule(rule)
        } catch {
            alert("Map Local failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Map Local from a sidebar path: copies the latest response at exactly `path`, else a blank rule for everything under it.
    func mock(host: String, path: String, sampleURL: String) -> String? {
        if let latest = index.byHost[host]?.last(where: { $0.pathOnly == path }) { return mock(latest) }
        return saveRule(MockRule(name: host + path, urlPattern: sampleURL + "/*", body: "{}"))
    }

    /// Sidebar Delete for a host, app or path; `source` names it in the confirmation.
    func confirmDeleteFlows(_ flows: [Flow], from source: String) {
        guard !flows.isEmpty, confirm("Delete \(flows.count) flows from \(source)?",
                                      "Their requests, responses and WebSocket messages will be deleted. This can't be undone.") else { return }
        deleteFlows(Set(flows.map(\.id)))
    }

    /// Blank rule for the "+" button.
    func newRule() -> String? {
        saveRule(MockRule(name: "New Rule", urlPattern: "https://example.com/*", body: "{}"))
    }

    private func saveRule(_ rule: MockRule) -> String? {
        do {
            try RuleStore.save(rule)
            reloadRules()
            return rule.id
        } catch {
            alert("Map Local failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Creates a script scoped to `url` (or opens the one already scoped to it); returns its file name for the editor.
    @discardableResult
    func addScript(for url: String, method: String? = nil) -> String? {
        let base = url.components(separatedBy: "?")[0]
        let target = ScriptStore.fileName(forURL: base, method: method)
        if target.exists {
            reloadRules()
            return target.fileName
        }
        var meta = ScriptMeta()
        meta.name = "\(method ?? "ANY") \(base)"
        meta.match = base + "*"
        meta.method = method
        return createScript(fileName: target.fileName, meta: meta)
    }

    func newScript() -> String? {
        var meta = ScriptMeta()
        meta.name = "New Script"
        meta.match = "https://example.com/*"
        var used = Set(ScriptStore.fileNames())
        return createScript(fileName: ScriptStore.uniqueFileName(for: "script", used: &used), meta: meta)
    }

    static let scriptTemplate = """
    // req = {method, url, headers, body}; return it to apply changes.
    function onRequest(req) {
      return req;
    }

    // res = {status, headers, body}; e.g. var json = JSON.parse(res.body); res.body = JSON.stringify(json);
    function onResponse(req, res) {
      return res;
    }

    """

    private func createScript(fileName: String, meta: ScriptMeta) -> String? {
        do {
            try ScriptStore.create(fileName: fileName, meta: meta, code: Self.scriptTemplate)
        } catch {
            alert("Add script failed: \(error.localizedDescription)")
            return nil
        }
        reloadRules()
        return fileName
    }

    func setScriptEnabled(_ name: String, _ enabled: Bool) {
        do { try ScriptMeta.setEnabled(enabled, file: Paths.scripts.appendingPathComponent(name)) } catch {
            alert("Could not update \(name): \(error.localizedDescription)")
        }
        reloadRules()
    }

    func deleteScript(_ name: String) {
        do { try ScriptStore.delete(fileName: name) } catch {
            alert("Delete failed: \(error.localizedDescription)")
        }
        reloadRules()
    }

    func setEnabled(_ rule: MockRule, _ enabled: Bool) {
        var r = rule
        r.enabled = enabled
        do { try RuleStore.save(r) } catch {
            alert("Could not update \(rule.name.isEmpty ? rule.urlPattern : rule.name): \(error.localizedDescription)")
        }
        reloadRules()
    }

    func delete(_ rule: MockRule) {
        do { try RuleStore.delete(rule) } catch {
            alert("Delete failed: \(error.localizedDescription)")
        }
        reloadRules()
    }
}
