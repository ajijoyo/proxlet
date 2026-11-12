# Proxlet

A native macOS HTTPS debugging proxy. Inspect traffic from your Mac, iOS simulators, phones and Android emulators; mock responses with Map Local; rewrite them with JavaScript; and let AI agents do the same through a built-in MCP server.

- HTTPS decryption per domain (SSL Proxying list)
- Map Local: text or binary bodies (images, video, any file), optional response delay
- Scripting: `onRequest` / `onResponse` in JavaScript
- Read-only WebSocket capture
- Advanced flow filter (URL, query string, method, status, headers, bodies, device; AND / OR)
- No Caching switch, device access control, image previews
- Import/export: HAR, Charles `.chls`, Map Local files and rule trees, scripting `.config`
- MCP server (`proxlet-mcp`) with 33 tools

Requires macOS 14 or later and Xcode / Swift 6 toolchain to build.
<img width="1304" height="1088" alt="Screenshot 2026-11-12 at 14 28 32" src="https://github.com/user-attachments/assets/a77e6094-bce0-4f70-bcd8-dc144ab17c32" />

## Install

```bash
git clone git@github.com:ajijoyo/proxlet.git
cd proxlet
./make-app.sh                     # release build → /Applications/Proxlet.app
open /Applications/Proxlet.app
```

Quit Proxlet before running `./make-app.sh` again (`osascript -e 'quit app "Proxlet"'`).

The proxy listens on port **9191** (change it in Settings, ⌘,). The bottom bar shows the address to use, e.g. `Listening on 192.168.1.16:9191`.

## First-time setup

Proxlet creates its own root certificate (CA) on first start. A client only accepts decrypted HTTPS after it trusts that CA.

| Client | Trust the CA | Route traffic through Proxlet |
|---|---|---|
| This Mac (Safari, Chrome, native apps) | **Certificate › Trust CA on this Mac**, then approve the macOS password / Touch ID prompt | Toolbar **System Proxy** button |
| iOS Simulator | **Certificate › Simulator (all booted)** | Follows the Mac's system proxy |
| iPhone | **Certificate › Real Device…** (iOS): scan the QR code, install the profile, then turn it on in Settings › General › About › **Certificate Trust Settings** | Wi-Fi › (i) › Configure Proxy › Manual: the Mac's IP and port |
| Android emulator | **Certificate › Emulator…** › **Push CA & Open Settings**, then Encryption & credentials › Install a certificate › CA certificate › `Proxlet-CA.crt` | Same window: **Set Proxy** (uses `10.0.2.2`) |
| Android phone | **Certificate › Real Device…** (Android) | Wi-Fi › Modify › Proxy: Manual |

Notes:
- Android apps only trust user CAs if their `network_security_config` allows it (typically debug builds). Chrome does.
- Phones can also download the CA from `http://<mac-ip>:9191/ssl`.
- The CA is valid for 825 days by default. **Settings › Certificate** shows its expiry and can regenerate it; after regenerating, trust the new CA again on every device.
- Apps that pin certificates can't be decrypted by any proxy.

### Choose what gets decrypted

The **SSL Proxying list starts empty**: HTTPS passes through untouched and shows up only as a `CONNECT` row. Enable the domains you want to inspect:

- Right-click a domain in the sidebar › **Enable SSL Proxying** (or `*.domain`)
- **Proxy › SSL Proxying List…** (⌥⌘S): Include / Exclude lists, wildcards like `*.example.com`
- The detail of a `CONNECT` flow has an **Enable SSL Proxying** button

Map Local and scripts only apply to decrypted hosts.

### Phones on your network

New devices on your Wi-Fi are **asked before they can use the proxy** (Allow / Deny). This Mac, simulators and emulators are always allowed. Manage the list in **Proxy › Access Control…** (⌥⌘A), or switch it to *Allow all*.

## Using it

### Flows
- The sidebar groups traffic by **Pinned**, **Apps** and **Domains** (host › path tree). Right-click for Pin, Map Local, Add Script, SSL Proxying and **Delete … Flows**. Filter hosts with the field at the bottom (⌘⇧F).
- The toolbar quick search filters by URL or method.
- **Filter** button (⌘F) opens the advanced filter: rows of *field · matching · text*, combined with AND / OR. Edits apply on **Apply** or ↩. Shortcuts: ⌘N new row, ⌘↑ / ⌘↓ move between rows, ⌘B all rows on/off, Esc hide.
- **Play / Pause** stops recording without stopping the proxy. **Clear** deletes all flows.
- The detail view shows headers, body (JSON highlighted, images previewed) and raw message; WebSocket flows show their messages.

### Map Local
Return a local response instead of calling the server.

- From a flow: right-click › **Map Local**, or the **Map Local** button in the detail. Image responses are copied as binary files.
- From scratch: **Map Local** in the sidebar › **New**.
- The editor uses HTTP message format (`HTTP/1.1 200 OK`, headers, blank line, body).
- **Select Binary File…** serves any file as the body (Content-Type from the extension when no header is set). **Remove Binary File** brings the text body back.
- **Delay**: Immediately, 1–3 seconds, or a custom value in milliseconds.
- URL patterns use `*` wildcards, or regex.
- A rule can be limited to specific devices: an iOS simulator by UDID, or a phone by its IP. A rule for the requesting device wins over rules without devices. Set devices through MCP (`device_ids`); the rule list shows them as badges.

### Scripts
JavaScript files that change requests and responses. Create one with right-click › **Add Script**, or **Scripts › New**.

```js
// @name Add header
// @match https://api.example.com/*
// @method ANY
// @request true
// @response true
function onRequest(req) {
  req.headers["X-Debug"] = "1";
  return req;
}

function onResponse(req, res) {
  var json = JSON.parse(res.body);
  json.flag = true;
  res.body = JSON.stringify(json);
  return res;
}
```

The four-argument form `onResponse(context, url, request, response)` (with `response.statusCode` and a parsed JSON body) is also supported. Each call has a 2-second time limit; errors show on the flow.

### Switches
**Proxy › No Caching** strips caching from every decrypted response (Map Local and scripted traffic is never cacheable either way). The bottom bar shows the state of System Proxy, Map Local, Scripts and No Caching.

### Import / export
- **File › Import…** (⌘O): `.har`, Charles `.chls` (needs Charles installed), and response files in HTTP message format (become Map Local rules).
- **File › Export Session…** (⌘⇧E): `.har` or `.chls`.
- Map Local and Scripts pages have their own Import / Export for rule trees and scripting `.config` files.

## MCP server

Proxlet ships `proxlet-mcp`, a stdio MCP server that reads and writes the same data as the app, so an agent can inspect traffic and create mocks while you use the app.

```bash
claude mcp add proxlet -- /Applications/Proxlet.app/Contents/MacOS/proxlet-mcp
```

| Area | Tools |
|---|---|
| Flows | `get_flows`, `get_flow_detail`, `filter_flows`, `export_flow_curl`, `export_flows`, `clear_session` |
| WebSocket | `list_websocket_sessions`, `get_websocket_messages` |
| Map Local / Scripts | `list_rules`, `create_map_local`, `create_map_local_from_flow`, `update_map_local`, `create_scripting_rule`, `update_scripting_rule`, `toggle_rule`, `delete_rule` |
| SSL Proxying | `enable_ssl_proxying`, `disable_ssl_proxying`, `get_ssl_proxying_list`, `toggle_ssl_proxying_domain` |
| Switches & status | `get_proxy_status`, `toggle_recording`, `toggle_tool`, `toggle_no_caching`, `list_tool_status`, `set_system_proxy`, `get_system_proxy_status` |
| Setup | `get_certificate_status`, `get_version`, `get_access_control`, `set_access_control_mode`, `allow_device`, `remove_device` |

Example prompts: *"Show the last 4xx responses from api.example.com"*, *"Mock GET /v1/profile with a 500 and a 2-second delay"*, *"Mock GET /v1/profile only for the booted simulator"*, *"Enable SSL Proxying for \*.example.com"*.

Changes made through MCP reach the running app within about 2 seconds.

## Data

Everything lives in `~/Library/Application Support/Proxlet` (**Certificate › Reveal Data Folder**):

| Path | Contents |
|---|---|
| `flows.jsonl` | Recorded flows (rotated at 50 MB) |
| `rules/*.json`, `map-local-files/` | Map Local rules and their binary bodies |
| `scripts/*.js` | Scripts |
| `websockets/`, `bodies/` | WebSocket messages, image response bytes |
| `state.json`, `ssl-proxying.json`, `access.json`, `theme.json` | Switches, SSL list, allowed devices, colors |
| `ca.pem`, `ca-key.pem` | The root CA (keep `ca-key.pem` private) |

Rules and scripts are plain files: editing them in a text editor takes effect immediately.

Quitting Proxlet turns the Mac's system proxy off again if it still points at Proxlet.

## Development

```bash
swift build                  # debug build of all targets
swift test                   # ~7 s, uses local test servers
swiftlint lint               # keep at 0 violations
swift run Proxlet            # run without bundling
```

`PROXLET_HOME=/tmp/proxlet` points the app and MCP at a throwaway data folder. Architecture notes for contributors are in [CLAUDE.md](CLAUDE.md).

## License

MIT © 2026 Aji. See [LICENSE](LICENSE).

Dependencies are fetched by Swift Package Manager under their own licenses (Apache-2.0 and MIT; BoringSSL inside swift-nio-ssl / swift-crypto). If you distribute a built `Proxlet.app`, include their notices.
