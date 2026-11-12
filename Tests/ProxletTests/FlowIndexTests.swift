//
//  FlowIndexTests.swift
//  ProxletTests
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import Proxlet
import ProxletCore
import XCTest

final class FlowIndexTests: XCTestCase {
    private func flow(_ url: String, agent: String) -> Flow {
        Flow(request: ProxyRequest(method: "GET", url: url, headers: [Header(name: "User-Agent", value: agent)], body: Data()),
             response: ProxyResponse(status: 200, headers: [], body: Data()), startedAt: Date(), mocked: false, error: nil)
    }

    func testGroupsByHostAndAppInOrder() {
        let flows = [flow("https://b.example/1", agent: "zeta/1 CFNetwork"), flow("https://a.example/1", agent: "Alpha/1 CFNetwork"),
                     flow("https://b.example/2", agent: "beta/1 CFNetwork"), flow("about:blank", agent: "beta/1 CFNetwork")]
        let index = FlowIndex(flows)
        XCTAssertEqual(index.hosts, ["a.example", "b.example"], "sorted, flows without a host left out")
        XCTAssertEqual(index.byHost["b.example"]?.map(\.url), ["https://b.example/1", "https://b.example/2"], "capture order kept")
        XCTAssertEqual(index.apps, ["Alpha", "beta", "zeta"], "case-insensitive")
        XCTAssertEqual(index.byApp["beta"]?.count, 2)
        XCTAssertEqual(index.byID[flows[2].id]?.url, "https://b.example/2")
        XCTAssertEqual(index.trees["b.example"]?.map(\.name), ["1", "2"])
        XCTAssertNil(index.trees["b.example"]?.first?.outlineChildren, "leaves have no disclosure triangle")
        XCTAssertTrue(FlowIndex().hosts.isEmpty)
    }
}
