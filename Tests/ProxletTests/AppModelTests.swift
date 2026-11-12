//
//  AppModelTests.swift
//  ProxletTests
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import Proxlet
@testable import ProxletCore
import XCTest

@MainActor
final class AppModelTests: XCTestCase {
    private var model: AppModel!
    private var alerts: [String] = []
    private var confirms: [String] = []
    private var answer = true

    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    override func setUp() async throws {
        Paths.root = FileManager.default.temporaryDirectory.appendingPathComponent("proxlet-model-test-\(UUID().uuidString)")
        try Paths.ensure()
        alerts = []
        confirms = []
        answer = true
        model = AppModel(startProxy: false)
        model.alertHandler = { [unowned self] in alerts.append($0) }
        model.confirmHandler = { [unowned self] title, _ in
            confirms.append(title)
            return answer
        }
    }

    override func tearDown() async throws {
        model = nil
        try? FileManager.default.removeItem(at: Paths.root)
    }

    private func flow(_ url: String, method: String = "GET", contentType: String = "application/json",
                      body: Data = Data(#"{"ok":true}"#.utf8), at time: TimeInterval = 1_000) -> Flow {
        Flow(request: ProxyRequest(method: method, url: url, headers: [], body: Data()),
             response: ProxyResponse(status: 200, headers: [Header(name: "Content-Type", value: contentType)], body: body),
             startedAt: Date(timeIntervalSince1970: time), mocked: false, error: nil)
    }

    /// Polls until `condition` holds (flow batching and detached file writes are asynchronous).
    private func eventually(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        let held = condition()
        XCTAssertTrue(held, what)
    }

    // MARK: - Map Local

    func testRuleLifecycle() throws {
        let id = try XCTUnwrap(model.newRule())
        XCTAssertEqual(model.rules.map(\.id), [id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: RuleStore.file(id).path))

        model.setEnabled(model.rules[0], false)
        XCTAssertEqual(model.rules.first?.enabled, false, "the change is saved and reloaded")

        model.delete(model.rules[0])
        XCTAssertTrue(model.rules.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RuleStore.file(id).path))
        XCTAssertEqual(alerts, [])
    }

    func testMockFromFlowCopiesTextAndRefusesWhatItCannotCopy() throws {
        let text = flow("https://api.test/users?id=1", body: Data(#"{"name":"aji"}"#.utf8))
        let id = try XCTUnwrap(model.mock(text))
        let rule = try XCTUnwrap(model.rules.first { $0.id == id })
        XCTAssertEqual(rule.urlPattern, "https://api.test/users?id=1")
        XCTAssertEqual(rule.body, #"{"name":"aji"}"#)
        XCTAssertNil(rule.bodyFile)

        XCTAssertNil(model.mock(flow("https://secret.test", method: "CONNECT")))
        XCTAssertTrue(alerts.last?.contains("isn't decrypted") == true, alerts.description)

        let video = flow("https://cdn.test/clip.mp4", contentType: "video/mp4", body: Data([0x00, 0xFF, 0xFE]))
        XCTAssertTrue(video.hasPartialResponseBody)
        XCTAssertNil(model.mock(video), "no bytes are kept for a non-image binary")
        XCTAssertTrue(alerts.last?.contains("placeholder") == true, alerts.description)
        XCTAssertEqual(model.rules.count, 1, "refused flows create no rule")
    }

    func testMockFromImageFlowUsesTheStoredBytes() throws {
        let image = flow("https://cdn.test/logo.png", contentType: "image/png", body: Self.png)
        model.store.append(image, responseBody: Self.png)
        let id = try XCTUnwrap(model.mock(image))
        let rule = try XCTUnwrap(model.rules.first { $0.id == id })
        XCTAssertTrue(RuleStore.isOwned(try XCTUnwrap(rule.bodyFile)))
        XCTAssertEqual(rule.response().body, Self.png)
        XCTAssertEqual(alerts, [])
    }

    func testMockFromSidebarPath() throws {
        model.flows = [flow("https://api.test/v1/users", body: Data(#"{"old":1}"#.utf8), at: 1),
                       flow("https://api.test/v1/users", body: Data(#"{"new":2}"#.utf8), at: 2),
                       flow("https://api.test/v1/items/9", at: 3)]

        let exact = try XCTUnwrap(model.mock(host: "api.test", path: "/v1/users", sampleURL: "https://api.test/v1/users"))
        XCTAssertEqual(model.rules.first { $0.id == exact }?.body, #"{"new":2}"#, "the latest response at that path")

        let folder = try XCTUnwrap(model.mock(host: "api.test", path: "/v1", sampleURL: "https://api.test/v1"))
        let blank = try XCTUnwrap(model.rules.first { $0.id == folder })
        XCTAssertEqual(blank.urlPattern, "https://api.test/v1/*", "a folder gets a blank rule for everything under it")
        XCTAssertEqual(blank.body, "{}")
    }

    // MARK: - Scripts

    func testScriptsAreCreatedOncePerURLAndToggled() throws {
        let name = try XCTUnwrap(model.addScript(for: "https://api.test/v1/users?id=7", method: "GET"))
        XCTAssertEqual(model.scripts, [name])
        let meta = try XCTUnwrap(model.scriptMeta[name])
        XCTAssertEqual(meta.match, "https://api.test/v1/users*", "the query is dropped")
        XCTAssertEqual(meta.method, "GET")
        XCTAssertEqual(meta.name, "GET https://api.test/v1/users")

        XCTAssertEqual(model.addScript(for: "https://api.test/v1/users", method: "GET"), name, "reopens instead of duplicating")
        XCTAssertEqual(model.scripts.count, 1)

        let first = try XCTUnwrap(model.newScript())
        let second = try XCTUnwrap(model.newScript())
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.scripts.count, 3)

        model.setScriptEnabled(name, false)
        XCTAssertEqual(model.scriptMeta[name]?.enabled, false)
        XCTAssertEqual(alerts, [])

        // A real delete moves the file to the user's Trash, so only the failure path runs here.
        model.deleteScript("missing.js")
        XCTAssertTrue(alerts.last?.hasPrefix("Delete failed") == true, alerts.description)
        model.setScriptEnabled("missing.js", true)
        XCTAssertTrue(alerts.last?.hasPrefix("Could not update missing.js") == true, alerts.description)
    }

    // MARK: - Flows

    func testDeleteFlowsAndTheirFiles() async throws {
        let keep = flow("https://a.test/keep")
        let image = flow("https://a.test/logo.png", contentType: "image/png", body: Self.png)
        model.store.append(keep)
        model.store.append(image, responseBody: Self.png)
        WebSocketStore.append(WebSocketMessage(time: Date(), direction: "send", type: "text", size: 2, text: "hi"), flowID: image.id)
        await eventually("both flows published") { model.flows.count == 2 }

        answer = false
        model.confirmDeleteFlows([image], from: "a.test")
        XCTAssertEqual(confirms, ["Delete 1 flows from a.test?"])
        XCTAssertEqual(model.flows.count, 2, "cancel keeps everything")

        answer = true
        model.confirmDeleteFlows([image], from: "a.test")
        XCTAssertEqual(model.flows.map(\.id), [keep.id])
        await eventually("deleted from flows.jsonl") { FlowStore.load().map(\.id) == [keep.id] }
        await eventually("its image and WebSocket files go too") {
            BodyStore.load(flowID: image.id) == nil && WebSocketStore.load(flowID: image.id).isEmpty
        }

        model.confirmDeleteFlows([], from: "nothing")
        XCTAssertEqual(confirms.count, 2, "an empty selection never asks")

        model.clearFlows()
        XCTAssertTrue(model.flows.isEmpty)
        XCTAssertTrue(FlowStore.load().isEmpty)
    }

    func testImportsAreRecordedWhilePaused() async {
        model.recording = false
        XCTAssertFalse(model.store.isRecording)
        let imported = flow("https://imported.test/x")
        let message = WebSocketMessage(time: Date(), direction: "receive", type: "text", size: 1, text: "m")
        model.addImported([SessionArchive.Imported(flow: imported, messages: [message])])
        await eventually("imported flow published") { model.flows.map(\.id) == [imported.id] }
        XCTAssertEqual(FlowStore.load().map(\.id), [imported.id])
        XCTAssertEqual(WebSocketStore.load(flowID: imported.id).map(\.text), ["m"])

        model.store.append(flow("https://live.test/x"))
        XCTAssertEqual(FlowStore.load().count, 1, "live traffic is still not recorded")
    }

    // MARK: - Changes made by proxlet-mcp

    func testRefreshAppliesSwitchesClearAndSSLListFromOtherProcesses() throws {
        model.flows = [flow("https://old.test/1", at: 100), flow("https://new.test/2", at: 300)]
        SharedState.update {
            $0.recording = false
            $0.mapLocal = false
            $0.scripts = false
            $0.noCaching = true
            $0.clearedAt = Date(timeIntervalSince1970: 200)
        }
        try SSLProxying.update { $0.add("*.acme.test") }
        model.refresh()

        XCTAssertFalse(model.recording)
        XCTAssertFalse(model.store.isRecording, "the pipeline follows the switch")
        XCTAssertFalse(model.mapLocalOn)
        XCTAssertFalse(model.scriptsOn)
        XCTAssertTrue(model.noCachingOn)
        XCTAssertEqual(model.flows.map(\.url), ["https://new.test/2"], "flows captured after the clear stay")
        XCTAssertTrue(model.sslProxying.shouldDecrypt("api.acme.test"))
        XCTAssertEqual(SharedState.load().port, model.port, "the app publishes its port back")
        XCTAssertFalse(SharedState.load().running)

        model.flows = [flow("https://again.test/1", at: 150)]
        model.refresh()
        XCTAssertEqual(model.flows.count, 1, "the same clear isn't applied twice")
    }

    func testSwitchChangesArePublishedForMCP() {
        model.mapLocalOn = false
        XCTAssertFalse(SharedState.load().mapLocal)
        model.scriptsOn = false
        XCTAssertFalse(SharedState.load().scripts)
        model.noCachingOn = true
        XCTAssertTrue(SharedState.load().noCaching)
        XCTAssertTrue(SharedState.load().recording, "untouched fields keep their value")
    }

    func testSSLProxyingToggleFromTheSidebar() {
        model.setSSLProxying(true, for: "api.test")
        model.setSSLProxying(true, for: "*.test")
        XCTAssertTrue(model.sslProxying.shouldDecrypt("api.test"))
        XCTAssertEqual(SSLProxying.load(), model.sslProxying, "saved for the proxy and proxlet-mcp")

        model.setSSLProxying(false, for: "api.test")
        XCTAssertFalse(model.sslProxying.shouldDecrypt("api.test"), "both the host and *.test are turned off")
        XCTAssertEqual(model.sslProxying.include.count, 2, "entries are disabled, not removed")
    }

    func testFilterEditsApplyOnlyOnApplyAndStartEmpty() {
        XCTAssertFalse(model.filterPanelShown, "hidden on launch; filters aren't persisted")
        XCTAssertEqual(model.filterDraft.rows.map(\.filter), [FlowQuery.Filter(key: "url", value: "")], "one empty URL row")
        XCTAssertTrue(model.filterDraft.matchAll)

        model.filterDraft.rows[0].filter.value = "acme"
        XCTAssertTrue(model.appliedFilter.activeFilters.isEmpty, "typing doesn't filter yet")
        model.applyFilter()
        XCTAssertEqual(model.appliedFilter.activeFilters.map(\.value), ["acme"])
        XCTAssertEqual(model.appliedFilter, model.filterDraft)
    }

    func testClearKeepsOnlyFlowsCapturedAfterIt() {
        let cleared = Date(timeIntervalSince1970: 1_000)
        let kept = AppModel.keep([flow("https://x/1", at: 999), flow("https://x/2", at: 1_000), flow("https://x/3", at: 1_000.5),
                                  flow("https://x/4", at: 2_000)], after: cleared)
        XCTAssertEqual(kept.map(\.startedAt.timeIntervalSince1970), [1_000.5, 2_000], "a flow at the clear instant is removed")
        XCTAssertEqual(AppModel.keep([], after: cleared), [])
    }
}
