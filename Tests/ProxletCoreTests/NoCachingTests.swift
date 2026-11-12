//
//  NoCachingTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import ProxletCore
import XCTest

/// No Caching for plain traffic; Map Local and scripted traffic are never cacheable either way.
extension PipelineTests {
    func testNoCachingStripsCachingFromAllTrafficWhenOn() async throws {
        let upstream = try await TestUpstream.start()
        let base = "http://127.0.0.1:\(upstream.port)"
        let pipeline = FlowPipeline(store: FlowStore())
        let conditional = [Header(name: "If-None-Match", value: "\"v1\""), Header(name: "If-Modified-Since", value: "Wed, 11 Nov 2026 00:00:00 GMT")]
        func header(_ res: ProxyResponse, _ name: String) -> String? { res.headers.first { $0.name.lowercased() == name }?.value }

        // Off (the default): plain traffic is passed through as the client and server sent it.
        func sent() async throws -> [String: String] {
            let echo = await get(pipeline, "\(base)/echo", headers: conditional)
            return try XCTUnwrap(json(echo)["headers"] as? [String: String])
        }
        let sentOff = try await sent()
        XCTAssertEqual(sentOff["if-none-match"], "\"v1\"")
        let cachedOff = await get(pipeline, "\(base)/cached")
        XCTAssertEqual(header(cachedOff, "cache-control"), "max-age=3600")
        XCTAssertEqual(header(cachedOff, "etag"), "\"v1\"")

        // On: validators never reach the server and responses can't be stored.
        pipeline.noCachingEnabled = true
        let sentOn = try await sent()
        XCTAssertNil(sentOn["if-none-match"])
        XCTAssertNil(sentOn["if-modified-since"])
        let cachedOn = await get(pipeline, "\(base)/cached")
        XCTAssertEqual(header(cachedOn, "cache-control"), "no-store")
        XCTAssertNil(header(cachedOn, "etag"))
        XCTAssertNil(header(cachedOn, "last-modified"))

        // Scripted traffic is fresh even with the switch off.
        pipeline.noCachingEnabled = false
        try writeScript("s.js", "// @match \(base)/*\nfunction onResponse(req, res) { return res; }")
        let scripted = await get(pipeline, "\(base)/cached", headers: conditional)
        XCTAssertEqual(header(scripted, "cache-control"), "no-store")
        let sentScripted = try await sent()
        XCTAssertNil(sentScripted["if-none-match"])
        await upstream.stop()
    }
}
