//
//  main.swift
//  proxlet-mcp
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import MCP
import ProxletCore

// Stdio MCP server; reads/writes the same files the Proxlet app uses.

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func json(_ value: some Encodable) throws -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    return String(data: try enc.encode(value), encoding: .utf8) ?? ""
}

func json(any value: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(data: data, encoding: .utf8) ?? ""
}

/// Typed access to a tool call's arguments.
struct Args {
    let raw: [String: Value]

    func str(_ k: String) -> String? { raw[k]?.stringValue }
    func int(_ k: String) -> Int? { raw[k]?.intValue ?? raw[k]?.doubleValue.map { Int($0) } }
    func bool(_ k: String) -> Bool? { raw[k]?.boolValue }
    func required(_ k: String) throws -> String {
        guard let v = str(k), !v.isEmpty else { throw ToolError(message: "Missing argument \(k)") }
        return v
    }
    /// `.none` when omitted, `.some(nil)` for ANY.
    func method(_ k: String) -> String?? {
        guard let m = str(k) else { return .none }
        return .some(m.uppercased() == "ANY" ? nil : m.uppercased())
    }
    var limit: Int { min(max(int("limit") ?? 50, 1), 500) }
}

func findFlow(_ id: String) throws -> Flow {
    guard let flow = FlowStore.load().last(where: { $0.id == id }) else { throw ToolError(message: "No flow with id \(id)") }
    return flow
}

func findRule(_ id: String) throws -> MockRule {
    guard let rule = RuleStore.load().first(where: { $0.id == id }) else { throw ToolError(message: "No Map Local rule with id \(id)") }
    return rule
}

func summary(_ f: Flow) -> [String: Any] {
    ["id": f.id, "method": f.method, "url": f.url, "status": f.status, "duration_ms": f.durationMs,
     "started_at": ISO8601DateFormatter().string(from: f.startedAt), "client": f.app, "websocket": f.websocket,
     "map_local": f.mocked, "scripts": f.scripts]
}

// MARK: - Flow tools

func getFlows(_ a: Args) throws -> String {
    let flows = FlowStore.load().reversed().filter { f in
        (a.str("host_filter").map { f.host.localizedCaseInsensitiveContains($0) } ?? true)
            && (a.str("method_filter").map { f.method.caseInsensitiveCompare($0) == .orderedSame } ?? true)
            && (a.int("status_filter").map { f.status == $0 } ?? true)
    }
    return try json(any: flows.prefix(a.limit).map(summary))
}

func getFlowDetail(_ a: Args) throws -> String {
    let f = try findFlow(try a.required("flow_id"))
    let query = URLComponents(string: f.url)?.queryItems?.map { ["name": $0.name, "value": $0.value ?? ""] } ?? []
    var detail = summary(f)
    detail["query_params"] = query
    detail["request"] = ["headers": f.requestHeaders.map { ["name": $0.name, "value": $0.value] }, "body": f.requestBody]
    detail["response"] = ["headers": f.responseHeaders.map { ["name": $0.name, "value": $0.value] }, "body": f.responseBody]
    detail["matched_tools"] = (f.mocked ? ["map_local"] : []) + (f.scripts.isEmpty ? [] : ["scripting"])
    if let e = f.error { detail["error"] = e }
    return try json(any: detail)
}

func filterFlows(_ a: Args) throws -> String {
    var filters: [FlowQuery.Filter] = (a.raw["filters"]?.arrayValue ?? []).compactMap { v in
        guard let o = v.objectValue, let key = o["key"]?.stringValue, let value = o["value"]?.stringValue else { return nil }
        return FlowQuery.Filter(key: key, matching: o["matching"]?.stringValue ?? "contains", value: value,
                                caseSensitive: o["case_sensitive"]?.boolValue ?? false)
    }
    if let key = a.str("key"), let value = a.str("value") {
        filters.append(FlowQuery.Filter(key: key, matching: a.str("matching") ?? "contains", value: value,
                                        caseSensitive: a.bool("case_sensitive") ?? false))
    }
    guard !filters.isEmpty else { throw ToolError(message: "Provide key/value or filters") }
    try filters.forEach(FlowQuery.validate)
    let any = a.str("combination") == "or"
    let result = FlowStore.load().reversed().filter { FlowQuery.matches($0, filters, any: any) }
    return try json(any: result.prefix(a.limit).map(summary))
}

func exportFlows(_ a: Args) throws -> String {
    let format = try a.required("format").lowercased()
    guard ["har", "chls"].contains(format) else { throw ToolError(message: "format must be har or chls") }
    let url = FlowQuery.exportURL(path: try a.required("path"), format: format)
    let ids = a.raw["flow_ids"]?.arrayValue?.compactMap(\.stringValue)
    let flows = FlowStore.load().filter { ids == nil || ids!.contains($0.id) }
    try SessionArchive.export(flows, to: url)
    return "Exported \(flows.count) flows to \(url.path)"
}

func clearSession(_: Args) throws -> String {
    let ids = Set(FlowStore.load().map(\.id))
    FlowStore().clear()
    WebSocketStore.delete(flowIDs: ids)
    SharedState.update { $0.clearedAt = Date() }
    return "Cleared \(ids.count) flows"
}

func getWebSocketMessages(_ a: Args) throws -> String {
    let flow = try findFlow(try a.required("flow_id"))
    guard flow.websocket else { throw ToolError(message: "Flow \(flow.id) is not a WebSocket") }
    let direction = a.str("direction") ?? "all"
    let pingPong = a.bool("include_ping_pong") ?? false
    let payload = a.bool("include_payload") ?? true
    let messages = WebSocketStore.load(flowID: flow.id).filter { m in
        (direction == "all" || (direction == "client" ? m.direction == "send" : m.direction == "receive"))
            && (pingPong || (m.type != "ping" && m.type != "pong"))
    }
    return try json(any: messages.map { m -> [String: Any] in
        var o: [String: Any] = ["time": ISO8601DateFormatter().string(from: m.time),
                                "direction": m.direction == "send" ? "client" : "server", "type": m.type, "size": m.size]
        if payload { o["payload_preview"] = m.text }
        return o
    })
}

func listWebSocketSessions(_: Args) throws -> String {
    try json(any: FlowStore.load().filter(\.websocket).reversed().map { f -> [String: Any] in
        var o = summary(f)
        o["message_count"] = WebSocketStore.load(flowID: f.id).count
        return o
    })
}

// MARK: - Rule tools

func listRules(_ a: Args) throws -> String {
    let type = a.str("rule_type") ?? "all"
    var rules: [[String: Any]] = []
    if type == "all" || type == "maplocal" {
        rules += RuleStore.load().map { r in
            ["id": r.id, "type": "maplocal", "name": r.name, "url": r.urlPattern, "method": r.method ?? "ANY",
             "isEnabled": r.enabled, "isRegex": r.useRegex, "status_code": r.status]
        }
    }
    if type == "all" || type == "scripting" {
        rules += ScriptStore.list().map { s in
            ["id": s.id, "type": "scripting", "name": s.meta.name, "url": s.meta.match, "method": s.meta.method ?? "ANY",
             "isEnabled": s.meta.enabled, "isRegex": s.meta.useRegex,
             "enable_request": s.meta.onRequest, "enable_response": s.meta.onResponse]
        }
    }
    return try json(any: ["count": rules.count, "rules": rules])
}

func createMapLocal(_ a: Args) throws -> String {
    let contentType = a.str("content_type") ?? "application/json"
    let rule = MockRule(name: a.str("name") ?? "", method: a.method("method") ?? nil,
                        urlPattern: FlowQuery.withSubpaths(try a.required("url"), a.bool("include_paths")),
                        status: a.int("status_code") ?? 200,
                        headers: contentType.isEmpty ? [:] : ["Content-Type": contentType],
                        body: a.str("response_body") ?? "{}", bodyFile: try bodyFile(a), delayMs: try delay(a) ?? nil)
    try RuleStore.save(rule)
    return try json(rule)
}

func createMapLocalFromFlow(_ a: Args) throws -> String {
    let flow = try findFlow(try a.required("flow_id"))
    guard var rule = try MockRule.from(flow: flow, urlPattern: a.str("url")) else {
        throw ToolError(message: "Flow \(flow.id) only stored a placeholder body (binary that isn't an image, an image over 10 MB, or "
                        + "text over 1 MB); use create_map_local with response_body or response_body_file instead")
    }
    if let m = a.method("method") { rule.method = m }
    if let n = a.str("name") { rule.name = n }
    if let d = try delay(a) { rule.delayMs = d }
    rule.urlPattern = FlowQuery.withSubpaths(rule.urlPattern, a.bool("include_paths"))
    try RuleStore.save(rule)
    return try json(rule)
}

/// `delay_ms`: `.none` when omitted, `.some(nil)` for 0 (answer immediately).
func delay(_ a: Args) throws -> Int?? {
    guard a.raw["delay_ms"] != nil else { return .none }
    guard let ms = a.int("delay_ms"), (0...MockRule.maxDelayMs).contains(ms) else {
        throw ToolError(message: "delay_ms must be 0...\(MockRule.maxDelayMs)")
    }
    return .some(ms == 0 ? nil : ms)
}

/// `response_body_file`: an existing file served as the body (binary allowed).
func bodyFile(_ a: Args) throws -> String? {
    guard let path = a.str("response_body_file"), !path.isEmpty else { return nil }
    let full = (path as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: full) else { throw ToolError(message: "response_body_file \(path) does not exist") }
    return full
}

func updateMapLocal(_ a: Args) throws -> String {
    var rule = try findRule(try a.required("id"))
    if let n = a.str("name") { rule.name = n }
    if let u = a.str("url") { rule.urlPattern = u }
    rule.urlPattern = FlowQuery.withSubpaths(rule.urlPattern, a.bool("include_paths"))
    if let m = a.method("method") { rule.method = m }
    if let s = a.int("status_code") { rule.status = s }
    if let c = a.str("content_type") {
        rule.headers = rule.headers.filter { $0.key.lowercased() != "content-type" }
        rule.headers["Content-Type"] = c
    }
    if let b = a.str("response_body") {
        rule.body = b
        rule.bodyFile = nil
    }
    if let file = try bodyFile(a) { rule.bodyFile = file }
    if let d = try delay(a) { rule.delayMs = d }
    try RuleStore.save(rule)
    return try json(rule)
}

func createScriptingRule(_ a: Args) throws -> String {
    var meta = ScriptMeta()
    meta.name = a.str("name") ?? "Script"
    meta.match = FlowQuery.withSubpaths(try a.required("url"), a.bool("include_paths"))
    meta.useRegex = a.bool("use_regex") ?? false
    meta.method = a.method("method") ?? nil
    meta.onRequest = a.bool("enable_request") ?? true
    meta.onResponse = a.bool("enable_response") ?? true
    var used = Set(ScriptStore.fileNames())
    let file = try ScriptStore.create(fileName: ScriptStore.uniqueFileName(for: meta.name, used: &used),
                                      meta: meta, code: try a.required("script_content"))
    return try json(any: ["id": String(file.dropLast(3)), "type": "scripting", "name": meta.name, "url": meta.match])
}

func updateScriptingRule(_ a: Args) throws -> String {
    let url = try ScriptStore.url(forID: try a.required("id"))
    var (meta, code) = ScriptMeta.parse(try String(contentsOf: url, encoding: .utf8))
    if let n = a.str("name") { meta.name = n }
    if let u = a.str("url") { meta.match = u }
    meta.match = FlowQuery.withSubpaths(meta.match, a.bool("include_paths"))
    if let m = a.method("method") { meta.method = m }
    if let r = a.bool("use_regex") { meta.useRegex = r }
    if let r = a.bool("enable_request") { meta.onRequest = r }
    if let r = a.bool("enable_response") { meta.onResponse = r }
    if let c = a.str("script_content") { code = c }
    try meta.render(code: code).write(to: url, atomically: true, encoding: .utf8)
    return "Updated \(url.lastPathComponent)"
}

func ruleType(_ a: Args) throws -> String {
    let type = try a.required("rule_type")
    guard ruleTypes.contains(type) else { throw ToolError(message: "rule_type must be one of \(ruleTypes.joined(separator: ", "))") }
    return type
}

func toggleRule(_ a: Args) throws -> String {
    guard let enabled = a.bool("enabled") else { throw ToolError(message: "Missing argument enabled") }
    let id = try a.required("id")
    if try ruleType(a) == "scripting" {
        try ScriptMeta.setEnabled(enabled, file: try ScriptStore.url(forID: id))
    } else {
        var rule = try findRule(id)
        rule.enabled = enabled
        try RuleStore.save(rule)
    }
    return "Rule \(id) \(enabled ? "enabled" : "disabled")"
}

func deleteRule(_ a: Args) throws -> String {
    let id = try a.required("id")
    if try ruleType(a) == "scripting" {
        try ScriptStore.delete(fileName: try ScriptStore.url(forID: id).lastPathComponent)
        return "Moved script \(id) to the Trash"
    }
    try RuleStore.delete(try findRule(id))
    return "Deleted rule \(id)"
}

// MARK: - Status tools

func getProxyStatus(_: Args) throws -> String {
    let s = SharedState.load()
    return try json(any: ["recording": s.recording, "running": s.running, "port": s.port, "lan_ip": s.lanIP ?? "",
                          "ssl_proxying_domains": SSLProxying.load().include.filter(\.enabled).count,
                          "system_proxy": SystemProxy.isEnabled(port: s.port),
                          "map_local": s.mapLocal, "scripting": s.scripts, "no_caching": s.noCaching])
}

func toggleRecording(_ a: Args) throws -> String {
    let s = SharedState.update { $0.recording = a.bool("enabled") ?? !$0.recording }
    return "Recording \(s.recording ? "on" : "paused")"
}

func toggleTool(_ a: Args) throws -> String {
    let tool = try a.required("tool")
    guard toolNames.contains(tool) else { throw ToolError(message: "tool must be one of \(toolNames.joined(separator: ", "))") }
    let path: WritableKeyPath<SharedState, Bool> = tool == "map_local" ? \.mapLocal : tool == "scripting" ? \.scripts : \.noCaching
    let s = SharedState.update { $0[keyPath: path] = a.bool("enabled") ?? !$0[keyPath: path] }
    return "\(tool) \(s[keyPath: path] ? "enabled" : "disabled")"
}

func toggleNoCaching(_ a: Args) throws -> String {
    let s = SharedState.update { $0.noCaching = a.bool("enabled") ?? !$0.noCaching }
    return "No Caching \(s.noCaching ? "enabled" : "disabled")"
}

func listToolStatus(_: Args) throws -> String {
    let s = SharedState.load()
    return try json(any: ["count": 3, "tools": [["name": "map_local", "is_enabled": s.mapLocal],
                                                ["name": "scripting", "is_enabled": s.scripts],
                                                ["name": "no_caching", "is_enabled": s.noCaching]]])
}

func setSystemProxy(_ a: Args) throws -> String {
    guard let enabled = a.bool("enabled") else { throw ToolError(message: "Missing argument enabled") }
    let state = SharedState.load()
    // Pointing the Mac at a port nobody listens on would break all browsing.
    if enabled, !state.running { throw ToolError(message: "Proxlet is not running; open the app first") }
    try SystemProxy.setEnabled(enabled, port: state.port)
    return "System proxy \(enabled ? "→ 127.0.0.1:\(state.port)" : "off")"
}

func getSystemProxyStatus(_: Args) throws -> String {
    let port = SharedState.load().port
    return try json(any: ["enabled": SystemProxy.isEnabled(port: port), "host": "127.0.0.1", "port": port])
}

let handlers: [String: (Args) throws -> String] = [
    "get_flows": getFlows, "get_flow_detail": getFlowDetail, "filter_flows": filterFlows,
    "export_flow_curl": { a in FlowQuery.curl(try findFlow(try a.required("flow_id"))) },
    "export_flows": exportFlows, "clear_session": clearSession,
    "get_websocket_messages": getWebSocketMessages, "list_websocket_sessions": listWebSocketSessions,
    "list_rules": listRules, "create_map_local": createMapLocal, "create_map_local_from_flow": createMapLocalFromFlow,
    "update_map_local": updateMapLocal, "create_scripting_rule": createScriptingRule,
    "update_scripting_rule": updateScriptingRule, "toggle_rule": toggleRule, "delete_rule": deleteRule,
    "get_proxy_status": getProxyStatus, "toggle_recording": toggleRecording, "toggle_tool": toggleTool,
    "list_tool_status": listToolStatus, "enable_ssl_proxying": enableSSLProxying, "disable_ssl_proxying": disableSSLProxying,
    "get_ssl_proxying_list": getSSLProxyingList, "toggle_ssl_proxying_domain": toggleSSLProxyingDomain,
    "set_system_proxy": setSystemProxy, "get_system_proxy_status": getSystemProxyStatus,
    "toggle_no_caching": toggleNoCaching, "get_certificate_status": getCertificateStatus, "get_version": getVersion, "get_access_control": getAccessControl,
    "set_access_control_mode": setAccessControlMode, "allow_device": allowDevice, "remove_device": removeDevice,
]

func call(_ name: String, _ args: [String: Value]) throws -> String {
    guard let handler = handlers[name] else { throw ToolError(message: "Unknown tool \(name)") }
    return try handler(Args(raw: args))
}

let server = Server(
    name: "proxlet",
    version: Paths.appVersion,
    instructions: "Proxlet is a local HTTPS debugging proxy. "
        + "Use get_flows/filter_flows/get_flow_detail to inspect traffic, create_map_local or create_map_local_from_flow "
        + "to mock responses, and create_scripting_rule to rewrite them.",
    capabilities: .init(tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
await server.withMethodHandler(CallTool.self) { params in
    do {
        return .init(content: [.text(text: try call(params.name, params.arguments ?? [:]), annotations: nil, _meta: nil)], isError: false)
    } catch {
        return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
    }
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
