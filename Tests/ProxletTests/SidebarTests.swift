//
//  SidebarTests.swift
//  ProxletTests
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import Proxlet
import ProxletCore
import XCTest

final class SidebarTests: XCTestCase {
    private func flow(_ url: String) -> Flow {
        Flow(request: ProxyRequest(method: "GET", url: url, headers: [], body: Data()),
             response: ProxyResponse(status: 200, headers: [], body: Data()),
             startedAt: Date(), mocked: false, error: nil)
    }

    func testPathTreeAndPrefixFilter() {
        let flows = ["https://a.com/api/v1/users?x=1", "https://a.com/api/v1/items", "https://a.com/api/v2", "https://a.com/"]
            .map(flow)
        let tree = PathNode.tree(host: "a.com", scheme: "https", flows: flows)
        XCTAssertEqual(tree.map(\.path), ["/api"])
        XCTAssertEqual(tree.map(\.id), ["a.com/api"], "ids include the host so two hosts' /api never collide")
        XCTAssertEqual(tree[0].count, 3)
        XCTAssertEqual(tree[0].children.map(\.path), ["/api/v1", "/api/v2"])
        XCTAssertEqual(tree[0].children[0].children.map(\.path), ["/api/v1/items", "/api/v1/users"])
        let pinned = tree[0].scoped("pinned")
        XCTAssertEqual(pinned.id, "pinned|a.com/api")
        XCTAssertEqual(pinned.children[0].children.map(\.id), ["pinned|a.com/api/v1/items", "pinned|a.com/api/v1/users"])
        XCTAssertEqual(pinned.children[0].path, "/api/v1", "paths stay unscoped for tags and filters")
        XCTAssertEqual(tree[0].children[0].sampleURL, "https://a.com/api/v1")

        let v1 = SidebarItem.path(host: "a.com", path: "/api/v1")
        XCTAssertEqual(flows.filter(v1.matches).count, 2)
        XCTAssertFalse(SidebarItem.path(host: "a.com", path: "/api/v").matches(flows[0]))
    }

    func testWildcardPins() {
        XCTAssertEqual(SidebarView.wildcard(for: "api.acme.test"), "*.acme.test")
        XCTAssertNil(SidebarView.wildcard(for: "acme.test"))
        XCTAssertNil(SidebarView.wildcard(for: "192.168.1.1"))
        let pin = SidebarItem.hostPattern("*.acme.test")
        XCTAssertTrue(pin.matches(flow("https://api.acme.test/")))
        XCTAssertTrue(pin.matches(flow("https://img.acme.test/x")))
        XCTAssertFalse(pin.matches(flow("https://acme.test.evil.io/")))
    }

    func testScopedURLColumn() {
        let f = flow("https://web.acme.test/acme-mobile/charlie/status?x=1")
        XCTAssertEqual(SidebarItem.all.urlTitle, "URL")
        XCTAssertEqual(SidebarItem.all.displayURL(f), f.url)
        XCTAssertEqual(SidebarItem.host("web.acme.test").urlTitle, "web.acme.test/*")
        XCTAssertEqual(SidebarItem.host("web.acme.test").displayURL(f), "*/acme-mobile/charlie/status?x=1")
        let path = SidebarItem.path(host: "web.acme.test", path: "/acme-mobile")
        XCTAssertEqual(path.urlTitle, "web.acme.test/acme-mobile/*")
        XCTAssertEqual(path.displayURL(f), "*/charlie/status?x=1")
        XCTAssertEqual(SidebarItem.hostPattern("*.acme.test").displayURL(f), "web.acme.test/acme-mobile/charlie/status?x=1")
    }

    func testScopedTagsShareFilterButDiffer() {
        let f = flow("https://api.acme.test/api/x")
        let pinned = SidebarItem.tag(.path(host: "api.acme.test", path: "/api"), section: "pinned")
        XCTAssertNotEqual(pinned, SidebarItem.path(host: "api.acme.test", path: "/api"))
        XCTAssertTrue(pinned.matches(f))
        XCTAssertEqual(pinned.urlTitle, "api.acme.test/api/*")
        XCTAssertEqual(SidebarItem.tag(.host("a"), section: "domains"), .host("a"))
    }

    func testHostFilterIsCaseInsensitiveAndIgnoresBlankQueries() {
        let hosts = ["api.acme.test", "web.acme.test", "api.example.com"]
        XCTAssertEqual(SidebarView.filter(hosts, ""), hosts)
        XCTAssertEqual(SidebarView.filter(hosts, "   "), hosts, "spaces alone don't filter")
        XCTAssertEqual(SidebarView.filter(hosts, "ACME"), ["api.acme.test", "web.acme.test"])
        XCTAssertEqual(SidebarView.filter(hosts, " web "), ["web.acme.test"])
        XCTAssertEqual(SidebarView.filter(hosts, "nope"), [])
    }
}
