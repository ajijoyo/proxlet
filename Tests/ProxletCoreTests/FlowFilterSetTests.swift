//
//  FlowFilterSetTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import ProxletCore
import XCTest

final class FlowFilterSetTests: XCTestCase {
    private func flow(_ method: String, _ url: String, _ status: Int) -> Flow {
        Flow(request: ProxyRequest(method: method, url: url, headers: [], body: Data()),
             response: ProxyResponse(status: status, headers: [], body: Data()), startedAt: Date(), mocked: false, error: nil)
    }

    private lazy var flows = [
        flow("GET", "https://api.test/users?page=2&sort=asc", 200),
        flow("POST", "https://api.test/users", 201),
        flow("POST", "https://api.test/login", 401),
        flow("DELETE", "https://cdn.test/img/1", 404),
    ]

    private func row(_ key: String, _ matching: String, _ value: String, enabled: Bool = true) -> FlowFilterSet.Row {
        FlowFilterSet.Row(enabled: enabled, filter: FlowQuery.Filter(key: key, matching: matching, value: value))
    }

    private func urls(_ set: FlowFilterSet) -> [String] {
        let match = set.matcher()
        return flows.filter(match).map(\.url)
    }

    func testFieldsMethodStatusURLAndQueryString() {
        XCTAssertEqual(FlowQuery.value(of: "queryString", in: flows[0]), "page=2&sort=asc")
        XCTAssertEqual(FlowQuery.value(of: "queryString", in: flows[1]), "", "no query, empty, not the response body")
        XCTAssertEqual(urls(FlowFilterSet(rows: [row("method", "equal", "post")])),
                       ["https://api.test/users", "https://api.test/login"], "methods match case-insensitively")
        XCTAssertEqual(urls(FlowFilterSet(rows: [row("statusCode", "startWith", "4")])),
                       ["https://api.test/login", "https://cdn.test/img/1"], "4xx")
        XCTAssertEqual(urls(FlowFilterSet(rows: [row("url", "contains", "cdn")])), ["https://cdn.test/img/1"])
        XCTAssertEqual(urls(FlowFilterSet(rows: [row("queryString", "contains", "sort=asc")])), ["https://api.test/users?page=2&sort=asc"])
    }

    func testAndRequiresEveryRowOrRequiresAny() {
        let rows = [row("method", "equal", "POST"), row("statusCode", "startWith", "4")]
        XCTAssertEqual(urls(FlowFilterSet(rows: rows, matchAll: true)), ["https://api.test/login"])
        XCTAssertEqual(urls(FlowFilterSet(rows: rows, matchAll: false)),
                       ["https://api.test/users", "https://api.test/login", "https://cdn.test/img/1"])
    }

    func testRowsThatAreOffEmptyOrBadRegexDontFilter() {
        XCTAssertEqual(urls(FlowFilterSet()).count, 4, "a fresh set has one empty row and filters nothing")
        XCTAssertEqual(urls(FlowFilterSet(rows: [row("url", "contains", "cdn", enabled: false)])).count, 4)
        let badRegex = FlowFilterSet(rows: [row("url", "regex", "users("), row("method", "equal", "DELETE")])
        XCTAssertEqual(badRegex.activeFilters.map(\.key), ["method"])
        XCTAssertEqual(urls(badRegex), ["https://cdn.test/img/1"], "an invalid regex doesn't empty the list under AND")
        XCTAssertEqual(urls(FlowFilterSet(rows: [row("url", "regex", "/users$")])), ["https://api.test/users"])
        XCTAssertFalse(FlowQuery.isValidRegex("("))
    }

    func testAddRemoveAndToggleAll() {
        var set = FlowFilterSet()
        let first = set.rows[0].id
        let added = set.addRow(after: first)
        let third = set.addRow(after: nil)
        XCTAssertEqual(set.rows.map(\.id), [first, added, third], "after the given row, else at the end")
        let middle = set.addRow(after: first)
        XCTAssertEqual(set.rows.map(\.id), [first, middle, added, third])

        set.removeRow(middle)
        set.removeRow(added)
        set.removeRow(third)
        set.rows[0].filter.value = "x"
        set.removeRow(first)
        XCTAssertEqual(set.rows.count, 1, "the last row stays")
        XCTAssertEqual(set.rows[0].id, first)
        XCTAssertEqual(set.rows[0].filter.value, "", "and is cleared instead")

        set.addRow(after: nil)
        set.rows[1].enabled = false
        set.toggleAll()
        XCTAssertEqual(set.rows.map(\.enabled), [false, false], "any row on: all go off")
        set.toggleAll()
        XCTAssertEqual(set.rows.map(\.enabled), [true, true], "all off: all come back on")
    }

    func testQuickSearchMovesIntoThePanel() {
        var set = FlowFilterSet()
        let first = set.rows[0].id
        set.adopt(search: "  acme ")
        XCTAssertEqual(set.rows.map(\.id), [first], "fills the empty row instead of adding one")
        XCTAssertEqual(set.rows[0].filter, FlowQuery.Filter(key: "url", value: "acme"))
        set.adopt(search: "api")
        XCTAssertEqual(set.rows.map(\.filter.value), ["acme", "api"], "no empty row left: appended")
        set.adopt(search: "   ")
        XCTAssertEqual(set.rows.count, 2, "blank search adds nothing")
        XCTAssertEqual(urls(set), [], "AND of both: no flow has acme")
    }

    func testMCPFilterBehaviourIsUnchanged() {
        let empty = FlowQuery.Filter(key: "url", value: "")
        XCTAssertFalse(FlowQuery.matches(flows[0], [empty], any: false), "filter_flows keeps Swift's contains(\"\") == false")
        let bad = FlowQuery.Filter(key: "url", matching: "regex", value: "(")
        XCTAssertFalse(FlowQuery.matches(flows[0], [bad], any: false), "an invalid regex still matches nothing for filter_flows")
    }

    func testFilteringThousandsOfFlowsIsQuick() {
        let many = (0..<5000).map { flow($0 % 2 == 0 ? "GET" : "POST", "https://h\($0 % 50).test/api/v1/items/\($0)?q=\($0)", 200 + $0 % 300) }
        let set = FlowFilterSet(rows: [row("url", "regex", #"/items/\d*4\?"#), row("method", "equal", "GET"),
                                       row("statusCode", "startWith", "2")])
        let start = Date()
        let match = set.matcher()
        let hits = many.filter(match).count
        print(String(format: "BENCH filter 5000 flows × 3 rows (1 regex): %.1f ms, %d hits", Date().timeIntervalSince(start) * 1000, hits))
        XCTAssertGreaterThan(hits, 0)
    }
}
