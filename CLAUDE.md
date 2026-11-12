# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Proxlet is a native macOS HTTPS debugging proxy with Map Local, JavaScript scripting, read-only WebSocket capture, and an MCP server so AI agents can inspect traffic and create mocks. SwiftPM only, no Xcode project.

## Commands

```bash
swift build                                   # all targets (debug)
swift test                                    # full suite (~5 s; uses local NIO servers and /usr/bin/curl)
swift test --filter ProxletCoreTests.FormatTests/testHARRoundTrip         # single test
swiftlint lint                                # config in .swiftlint.yml; keep it at 0 violations
swift run Proxlet                             # run the app from .build (no bundle, no icon)
./make-app.sh                                 # release build → build/Proxlet.app (+ icon, proxlet-mcp) → copied to /Applications
claude mcp add proxlet -- /Applications/Proxlet.app/Contents/MacOS/proxlet-mcp
```

- Version: change only `Paths.appVersion` (`ProxletCore/Paths.swift`); `make-app.sh` writes it to Info.plist with the commit count as build number. Tag releases `vX.Y.Z`.
- Quit the running app before `./make-app.sh` (`osascript -e 'quit app "Proxlet"'`), then `open /Applications/Proxlet.app`.
- `PROXLET_HOME=/some/dir` points app and MCP at a throwaway data dir instead of `~/Library/Application Support/Proxlet`. Tests override `Paths.root` themselves.
- Manual check through the proxy: `curl -x http://127.0.0.1:9191 --cacert ~/Library/Application\ Support/Proxlet/ca.pem https://httpbin.org/get`.
- `testCharlesSessionRoundTrip` skips unless `/Applications/Charles.app` exists; `testSocketScanFindsOwnConnection` skips unless the test runner lives inside an `.app` (Xcode).
- Core tests subclass `ProxletTestCase` (TestSupport.swift), which isolates `Paths.root` and provides `TestUpstream` (HTTP/HTTPS, CA-signed), `TestWebSocketServer` and `RawSocket`. App tests that touch `Paths` must isolate it the same way.

## Targets

- `ProxletCore` (library): proxy, pipeline, CA, rules, scripts, storage, archives. All non-UI logic goes here.
- `Proxlet` (SwiftUI executable): UI only. `ProxletApp.swift` holds scenes and menus; `AppModel` (the `@Observable` state) is split into `AppModel+Rules/Access/Certificate/SSL.swift` extensions. `ProxletTests` `@testable import`s this executable target.
- `proxlet-mcp` (stdio executable, modelcontextprotocol/swift-sdk). `Tools.swift` holds the schemas, `main.swift` one handler per tool (SSL Proxying in `SSLProxyingTools.swift`; certificate status, version and device access in `SetupTools.swift`); anything worth testing lives in ProxletCore (`FlowQuery`, `ScriptStore`, `RuleStore`, `SSLProxying`, `AccessControl`, `CertificateAuthority.status()`). The Map Local tools take `response_body_file`, `delay_ms` and `device_ids` (simulator UDIDs or network client IPs); device access has `get_access_control`, `set_access_control_mode`, `allow_device`, `remove_device`. MCP requests can run concurrently, so a client must await each reply before relying on ordering.
- `swiftLanguageModes: [.v5]` on purpose; NIO handler types are not Sendable.

## Architecture

**Files are the integration point.** The app and `proxlet-mcp` are separate processes that share `Paths.root`:
`rules/*.json` (Map Local, one file per rule), `scripts/*.js`, `flows.jsonl` (append-only, rotated at 50 MB), `websockets/<flow-id>.jsonl`, `state.json` (`SharedState`: recording / mapLocal / scripts / noCaching switches, port, `clearedAt`), `theme.json`, `access.json` (network clients allowed by `AccessControl`; loopback always allowed; re-read when another process changes it), `ssl-proxying.json`, `bodies/<flow-id>` (`BodyStore`: raw bytes of `image/*` responses up to 10 MB; flows.jsonl keeps only the `<binary N bytes>` placeholder), `map-local-files/` (binary Map Local bodies Proxlet copied from flows; deleted with their rule), `ca.pem`/`ca-key.pem` (CA lifetime set in Settings, default 825 days, used only when the CA is created or regenerated; leaves last 397 days, capped at the CA's expiry). Rules are re-read per request (`RuleStore`, which remembers each rule's source file so hand-named files round-trip) and scripts are cached by mtime, so edits apply without IPC. Scripts are listed/named/deleted through `ScriptStore` (id = file name minus `.js`, deletes go to the Trash) by both the app and MCP. The app polls `state.json`, rules, scripts and `ssl-proxying.json` every 2 s (`AppModel` refresh timer) and writes `state.json` on every switch change; MCP changes `state.json` to flip app switches or clear the session.

**Request path** (`ProxyServer.swift` → `FlowPipeline.handle`):
0. `AccessControl` runs in `childChannelInitializer`: a non-loopback client IP not yet allowed is held unread until the app's Allow/Deny prompt answers (one prompt per IP; denials last until restart). Simulators and emulators (`10.0.2.2`) arrive as loopback.
1. `ProxyHandler` decodes HTTP/1.1. `CONNECT` (authority parsed by `ProxyServer.authority`, IPv6 included) to a host outside the SSL Proxying list (`SSLProxying`, `ssl-proxying.json`, include minus exclude, empty by default) is relayed raw with `RawRelay` and recorded as a `CONNECT` flow only. Otherwise it answers 200 and swaps the pipeline to `NIOSSLServerHandler` with a per-host leaf cert from `CertificateAuthority` (iPAddress SAN for IP literals), then reinstalls itself with a `TunnelTarget` to rebuild absolute URLs. `Upgrade: websocket` goes to `startWebSocket` instead (see below).
2. `LocalPages` serves the CA download (`/ssl`, `/ssl.pem`, `/ssl.crt`, host `proxlet.ssl`).
3. Map Local (`RuleStore.match`) short-circuits; `onResponse` scripts still run on the mock. A rule with `devices` matches only those clients and wins over rules without `devices`. A client is an iOS simulator UDID (executable path under `CoreSimulator/Devices/<UDID>/`) or, for a network client such as a phone, its IP (`ClientApp`; `ProcessLookup.Client.device`, stored as `Flow.device`). Simulator daemons and Mac apps have no device and get general rules only; a phone's DHCP IP can change, so its rules then stop matching. Exported rules keep their devices, which match nothing on another Mac.
4. Otherwise `onRequest` scripts, upstream via AsyncHTTPClient, then `onResponse` scripts. Responses are buffered whole (no streaming, so long-lived SSE hits the 60 s read timeout). Content-Length is rebuilt from the body, except HEAD/304 keep the upstream value and 1xx/204 send none.
5. Mocked or scripted responses get `Cache-Control: no-store`, and scripted requests drop conditional headers, so toggling a rule or switch shows up on the next request. The No Caching switch (`FlowPipeline.noCachingEnabled`, off by default) does the same for all other decrypted traffic; tunneled (non-SSL-Proxying) hosts can't be touched.

Upstream gotchas that caused real bugs:
- The AsyncHTTPClient uses `MultiThreadedEventLoopGroup` (POSIX sockets). The default Network.framework transport honours the macOS system proxy and loops traffic back into Proxlet.
- Client decompression is disabled. `ContentDecoding` decodes gzip/deflate/br itself and passes undecodable bodies through unchanged (NIO's decompressor threw `truncatedData` on Google).

**WebSocket** (`WebSocket.swift`): read-only. The handshake is forwarded without `Sec-WebSocket-Extensions` (frames stay uncompressed), then `RawRelay` copies raw bytes both ways and tees them to `FrameParser`/`WebSocketRecorder`. Frames are never re-encoded. The parser gives up on frames over 16 MB (hostile lengths must not overflow) and recording stops at 10 000 messages per connection; the relay keeps working either way.

**Scripts** (`ScriptEngine`, `ScriptMeta`): each `.js` file starts with `// @name/@enabled/@match/@regex/@method/@request/@response` header lines, plus `@created` (ISO-8601, set on create/import; Map Local rules keep it as `createdAt`). The Map Local and Scripts lists show newest first; matching and script order stay by file name. Two calling conventions are chosen by function arity: two-argument `onRequest(req)` / `onResponse(req, res)` with `res.status`, and four-argument `onResponse(context, url, request, response)` with `response.statusCode` and JSON bodies pre-parsed. JavaScriptCore has no `URL` API, so URL parts are passed from Swift as `req._parts`. `console.log` is a no-op. Each script has its own JSContext and lock, and a 2 s execution limit (`JSContextGroupSetExecutionTimeLimit` via dlsym), so a runaway script only fails its own matches. Headers a script leaves untouched keep their original lines (duplicate `Set-Cookie` survives).

**Client app detection**: for loopback connections `ProcessLookup` maps the client's source port to a PID via libproc and resolves the outermost `.app` (helpers → parent app). `Flow.appName(userAgent:)` is the fallback (Electron product token before `Chrome/`).

**Interop formats** (verified against the real tools):
- Sessions: HAR 1.2 written and read natively (`SessionArchive`). `.chls` is Charles' Java-serialized format and goes through `Charles convert` (`CharlesConverter`).
- Map Local: HTTP-message files (`HTTP/1.1 200 OK`, headers, blank line, body; `HTTPMessageFormat` in Core) and `MapLocalFiles-RuleTree` JSON exports (`MapLocalArchive`, folders flattened by `Proxyman.RuleTree`), with a plain-file fallback. Binary bodies are a `bodyFile` path served as is, typed by extension when the rule has no Content-Type. `MockRule.from(flow:)` turns a placeholder body (`Flow.hasPartialResponseBody`) into a rule only when `BodyStore` has its bytes (images), copying them into `map-local-files/`. Exports inline only UTF-8 body files; binary ones keep their path.
- Scripts: the scripting `.config` export is gzip-compressed JSON `{"tree":[…fileContent…],"userFiles":[…]}` (`.ScriptConfig`). Run as Mock API and shared user files are not supported.

**UI performance**: `Flow` parses `host`/`path`/`pathSegments`/`app` once (stored, not persisted). `AppModel` publishes new flows in batches (300 ms, 1 s past 2000 flows) and rebuilds `FlowIndex` (by id/host/app plus each host's `PathNode` tree) once per change of `flows`; views read the index instead of grouping per render. The flow list is an `NSTableView` (`FlowTable`), not SwiftUI `Table`, which diffed every row per batch (330 ms at 20k flows): new flows are `insertRows` on top, anything else `reloadData`, so cost tracks visible rows only; it stays the `first` pane of one `ResizableSplit` (`showsSecond`) so opening a flow doesn't recreate it. The flow filter panel (`FlowFilterPanel`, rows in `FlowFilterSet`) reuses `FlowQuery` keys/matchings, so the UI and MCP `filter_flows` share fields (incl. `queryString`); rows that are off, empty or an invalid regex are skipped only in `FlowFilterSet`, never in `FlowQuery`, and `matcher()` compiles regex rows once per render. Filters are session-only (`AppModel.filterDraft`/`appliedFilter`, applied on Apply/↩). Only one filter is active at a time: the toolbar quick search (a plain `TextField` next to the Filter button, not `.searchable`) hides while the panel is open, and its text moves into the panel (`FlowFilterSet.adopt(search:)`). Every row id in the sidebar `List` must be unique across sections (`Keyed`, `PathNode.scoped`): duplicate ids made rows overlap and show two selections.

**System proxy**: set through `networksetup` (no privileged helper). `AppDelegate` turns it off on quit or SIGTERM, but only when `scutil --proxy` points exactly at 127.0.0.1:Proxlet's port, and writes `running: false` to state.json so MCP `set_system_proxy` refuses to enable a dead port. App-side switch changes write only the changed field of state.json.

## Conventions

- New Swift files use the Xcode header crediting "Aji", with `//  Copyright © <yyyy> Aji. Licensed under the MIT License.` as the copyright line (this repo is MIT; it replaces the global "GIT. All rights reserved." line).
- UI colors for JSON/HTTP/JS come from `Theme` in `Syntax.swift`. Every palette key is required; a `theme.json` that doesn't decode uses `Theme.default`. Adding a key later makes existing custom themes fall back, so ship that with its own migration.
- Delete actions go through `AppModel.confirm(...)` with "Delete" wording; sidebar flow deletes use `AppModel.confirmDeleteFlows`.
- SwiftLint's default limits (400 lines per file, 250 per type body) apply: split into a new file or extension (as done for `AppModel+*.swift`, `SSLProxyingTools.swift`) rather than raising limits.
- The app icon is generated from `icon.jpg` by `scripts/make-icon.swift` during `make-app.sh`.
