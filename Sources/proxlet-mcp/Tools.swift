//
//  Tools.swift
//  proxlet-mcp
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import MCP
import ProxletCore

// Tool definitions (schemas); handlers live in main.swift and the *Tools.swift files.

func schema(_ props: [String: Value], required: [String] = []) -> Value {
    .object(["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })])
}

func prop(_ type: String, _ description: String) -> Value {
    .object(["type": .string(type), "description": .string(description)])
}

func choice(_ values: [String], _ description: String) -> Value {
    .object(["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)])
}

let methods = MockRule.methods
let sslLists = SSLProxying.List.allCases.map(\.rawValue)
let ruleTypes = ["maplocal", "scripting"]
let toolNames = ["map_local", "scripting", "no_caching"]
let filterKeys = FlowQuery.keys
let matchings = FlowQuery.matchings

let tools: [Tool] = [
    // MARK: Flows
    Tool(name: "get_flows",
         description: "List the latest recorded requests, most recent first.",
         inputSchema: schema([
             "host_filter": prop("string", "Only hosts containing this text (any case)"),
             "method_filter": prop("string", "Only this request method, e.g. GET or POST"),
             "status_filter": prop("integer", "Only this response status, e.g. 404"),
             "limit": prop("integer", "How many flows to return at most (50 by default, up to 500)"),
         ])),
    Tool(name: "get_flow_detail",
         description: "Everything recorded for one flow: request and response headers and bodies, query parameters, "
             + "and whether Map Local or a script changed it.",
         inputSchema: schema(["flow_id": prop("string", "Flow ID from get_flows or filter_flows")], required: ["flow_id"])),
    Tool(name: "filter_flows",
         description: "Search recorded flows with one condition (key, matching, value) or a list of conditions joined by AND or OR.",
         inputSchema: schema([
             "key": choice(filterKeys, "Field to test"),
             "matching": choice(matchings, "How to compare (contains by default)"),
             "value": prop("string", "Text to compare with"),
             "case_sensitive": prop("boolean", "Compare with exact letter case (off by default)"),
             "filters": .object([
                 "type": "array", "description": "Array of {key, matching, value, case_sensitive}",
                 "items": .object(["type": "object", "properties": .object([
                     "key": choice(filterKeys, "Field to test"), "matching": choice(matchings, "How to compare"),
                     "value": prop("string", "Text to compare with"), "case_sensitive": prop("boolean", "Exact letter case"),
                 ]), "required": .array(["key", "value"])]),
             ]),
             "combination": choice(["and", "or"], "and: every condition must hold (default); or: any one"),
             "limit": prop("integer", "How many flows to return at most (50 by default, up to 500)"),
         ])),
    Tool(name: "export_flow_curl",
         description: "Turn a recorded request into a curl command line.",
         inputSchema: schema(["flow_id": prop("string", "Flow ID of the request to convert")], required: ["flow_id"])),
    Tool(name: "export_flows",
         description: "Save flows to a file as HAR, or as a Charles .chls session (requires Charles). Without flow_ids every flow is saved.",
         inputSchema: schema([
             "format": choice(["har", "chls"], "har or chls"),
             "path": prop("string", "Target file or folder; confirm the location with the user before saving."),
             "flow_ids": .object(["type": "array", "items": .object(["type": "string"]), "description": "Optional flow IDs to export"]),
         ], required: ["format", "path"])),
    Tool(name: "clear_session",
         description: "Remove every recorded flow from the app's list.",
         inputSchema: schema([:])),
    Tool(name: "get_websocket_messages",
         description: "Show the messages recorded on a WebSocket connection.",
         inputSchema: schema([
             "flow_id": prop("string", "Flow ID of the WebSocket connection"),
             "direction": choice(["all", "client", "server"], "client, server, or all (default)"),
             "include_payload": prop("boolean", "Add a payload_preview to each message (on by default)"),
             "include_ping_pong": prop("boolean", "Also list ping/pong frames (off by default)"),
         ], required: ["flow_id"])),
    Tool(name: "list_websocket_sessions",
         description: "WebSocket connections with how many messages each has.",
         inputSchema: schema([:])),

    // MARK: Rules
    Tool(name: "list_rules",
         description: "Map Local rules and scripts, with the IDs other tools need.",
         inputSchema: schema(["rule_type": choice(["all"] + ruleTypes, "maplocal, scripting, or all (default)")])),
    Tool(name: "create_map_local",
         description: "Answer matching requests with a response you define, without contacting the server. "
             + "To start from a recorded response, use create_map_local_from_flow.",
         inputSchema: schema([
             "url": prop("string", "URL to match; * matches anything"),
             "name": prop("string", "Rule name shown in the app"),
             "method": choice(methods, "Request method to match (ANY by default)"),
             "status_code": prop("integer", "Status to answer with (200 by default)"),
             "content_type": prop("string", "Content-Type of the answer (application/json by default)"),
             "response_body": prop("string", "Body text of the answer ({} by default)"),
             "response_body_file": prop("string", "Absolute path of a file to send as the body instead, e.g. an image. "
                                        + "Without content_type its type comes from the file extension."),
             "include_paths": prop("boolean", "Also match everything below the URL (off by default)"),
             "delay_ms": prop("integer", "Wait this many milliseconds before answering, 0 to 60000 (0 by default)"),
         ], required: ["url"])),
    Tool(name: "create_map_local_from_flow",
         description: "Make a Map Local rule that answers with a recorded response (status, headers and body).",
         inputSchema: schema([
             "flow_id": prop("string", "Flow ID of the recorded response"),
             "url": prop("string", "URL to match instead of the flow's own URL"),
             "method": choice(methods, "Method to match instead of the flow's own method"),
             "name": prop("string", "Rule name shown in the app"),
             "include_paths": prop("boolean", "Also match everything below the URL (off by default)"),
             "delay_ms": prop("integer", "Wait this many milliseconds before answering, 0 to 60000 (0 by default)"),
         ], required: ["flow_id"])),
    Tool(name: "update_map_local",
         description: "Change a Map Local rule (ID from list_rules); fields you leave out stay as they are.",
         inputSchema: schema([
             "id": prop("string", "The rule ID (obtain from list_rules)"),
             "name": prop("string", "New rule name"),
             "url": prop("string", "New URL to match"),
             "method": choice(methods, "HTTP method"),
             "status_code": prop("integer", "New status to answer with"),
             "content_type": prop("string", "New Content-Type"),
             "response_body": prop("string", "New body text"),
             "response_body_file": prop("string", "Absolute path of a file to send as the body"),
             "include_paths": prop("boolean", "Also match everything below the URL"),
             "delay_ms": prop("integer", "Wait this many milliseconds before answering, 0 to 60000 (0 by default)"),
         ], required: ["id"])),
    Tool(name: "create_scripting_rule",
         description: "Add a JavaScript script that edits matching requests and responses. Use onRequest(req) / onResponse(req, res) "
             + "returning the edited object, or onRequest(context, url, request) / onResponse(context, url, request, response), "
             + "which must end with `return request;` / `return response;` (response.statusCode, headers, body; JSON bodies are parsed).",
         inputSchema: schema([
             "url": prop("string", "URL to match: * wildcards, a regex with use_regex, or just a host like api.example.com"),
             "script_content": prop("string", "Script code"),
             "name": prop("string", "Script name shown in the app"),
             "method": choice(methods, "Request method to match (ANY by default)"),
             "use_regex": prop("boolean", "url is a regular expression (off by default)"),
             "enable_request": prop("boolean", "Run onRequest (on by default)"),
             "enable_response": prop("boolean", "Run onResponse (on by default)"),
             "include_paths": prop("boolean", "Also match everything below the URL (off by default)"),
         ], required: ["url", "script_content"])),
    Tool(name: "update_scripting_rule",
         description: "Change a script (ID from list_rules); fields you leave out stay as they are.",
         inputSchema: schema([
             "id": prop("string", "The rule ID (obtain from list_rules)"),
             "name": prop("string", "New rule name"),
             "url": prop("string", "New URL to match"),
             "method": choice(methods, "HTTP method"),
             "use_regex": prop("boolean", "url is a regular expression"),
             "enable_request": prop("boolean", "Run onRequest"),
             "enable_response": prop("boolean", "Run onResponse"),
             "script_content": prop("string", "New script code"),
             "include_paths": prop("boolean", "Also match everything below the URL"),
         ], required: ["id"])),
    Tool(name: "toggle_rule",
         description: "Switch one Map Local rule or script on or off.",
         inputSchema: schema([
             "id": prop("string", "The rule ID (obtain from list_rules)"),
             "rule_type": choice(ruleTypes, "Type of rule"),
             "enabled": prop("boolean", "true turns it on, false off"),
         ], required: ["id", "rule_type", "enabled"])),
    Tool(name: "delete_rule",
         description: "Delete one Map Local rule or script.",
         inputSchema: schema([
             "id": prop("string", "The rule ID (obtain from list_rules)"),
             "rule_type": choice(ruleTypes, "Type of rule"),
         ], required: ["id", "rule_type"])),

    // MARK: Status and switches
    Tool(name: "get_proxy_status",
         description: "Port, LAN address, whether recording and the system proxy are on, and the Map Local / Scripts / No Caching switches.",
         inputSchema: schema([:])),
    Tool(name: "toggle_recording",
         description: "Pause or resume recording; requests are still proxied while paused.",
         inputSchema: schema(["enabled": prop("boolean", "true records, false pauses; leave out to flip")])),
    Tool(name: "toggle_tool",
         description: "Turn Map Local, Scripts or No Caching on or off for all traffic.",
         inputSchema: schema([
             "tool": choice(toolNames, "map_local, scripting or no_caching"),
             "enabled": prop("boolean", "true turns it on, false off; leave out to flip"),
         ], required: ["tool"])),
    Tool(name: "enable_ssl_proxying",
         description: "Decrypt HTTPS for a domain. Other hosts pass through encrypted (only their CONNECT is recorded) "
             + "and Map Local and scripts can't touch them.",
         inputSchema: schema(["domain": prop("string", "Host or *.host pattern, e.g. api.example.com or *.example.com")],
                             required: ["domain"])),
    Tool(name: "disable_ssl_proxying",
         description: "Take a domain off the decrypt (include) or never-decrypt (exclude) list.",
         inputSchema: schema([
             "domain": prop("string", "Host or pattern as it appears in the list"),
             "list": choice(sslLists, "include (default) or exclude"),
         ], required: ["domain"])),
    Tool(name: "get_ssl_proxying_list",
         description: "The domains that are decrypted (include) and never decrypted (exclude), each with its on/off state.",
         inputSchema: schema([:])),
    Tool(name: "toggle_ssl_proxying_domain",
         description: "Switch one list entry on or off while keeping it in the list.",
         inputSchema: schema([
             "domain": prop("string", "Host or pattern as it appears in the list"),
             "enabled": prop("boolean", "true turns it on, false off"),
             "list": choice(sslLists, "include (default) or exclude"),
         ], required: ["domain", "enabled"])),
    Tool(name: "get_certificate_status",
         description: "Proxlet's root certificate: whether it exists, when it expires, and whether this Mac trusts it.",
         inputSchema: schema([:])),
    Tool(name: "get_version",
         description: "Proxlet's version number.",
         inputSchema: schema([:])),
    Tool(name: "get_access_control",
         description: "Which network devices (phones on Wi-Fi) may use the proxy, and whether new ones are asked first. "
             + "This Mac, simulators and Android emulators are always allowed.",
         inputSchema: schema([:])),
    Tool(name: "set_access_control_mode",
         description: "Ask before allowing new network devices, or allow all.",
         inputSchema: schema(["mode": choice(["ask", "allow_all"], "ask (default) or allow_all")], required: ["mode"])),
    Tool(name: "allow_device",
         description: "Allow a network device by IP address without the connection prompt.",
         inputSchema: schema(["ip": prop("string", "IPv4 or IPv6 address, e.g. 192.168.1.20")], required: ["ip"])),
    Tool(name: "remove_device",
         description: "Remove a device from the allow list; it is asked again on its next connection.",
         inputSchema: schema(["ip": prop("string", "IP address in the allow list")], required: ["ip"])),
    Tool(name: "toggle_no_caching",
         description: "Make every decrypted response uncacheable and drop If-None-Match / If-Modified-Since from requests. "
             + "Map Local and scripted traffic is always uncacheable.",
         inputSchema: schema(["enabled": prop("boolean", "true turns it on, false off; leave out to flip")])),
    Tool(name: "list_tool_status",
         description: "Whether Map Local, Scripts and No Caching are on.",
         inputSchema: schema([:])),
    Tool(name: "set_system_proxy",
         description: "Route this Mac's HTTP and HTTPS traffic through Proxlet, or stop doing so.",
         inputSchema: schema(["enabled": prop("boolean", "true routes traffic through Proxlet, false stops it")], required: ["enabled"])),
    Tool(name: "get_system_proxy_status",
         description: "Whether this Mac's traffic currently goes through Proxlet.",
         inputSchema: schema([:])),
]
