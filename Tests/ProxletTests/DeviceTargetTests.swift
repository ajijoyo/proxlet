//
//  DeviceTargetTests.swift
//  ProxletTests
//
//  Created by Aji on 15/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import XCTest
@testable import Proxlet

final class DeviceTargetTests: XCTestCase {
    func testGlobalClearsTargetsAndSpecificRequiresValidEntries() throws {
        XCTAssertNil(try DeviceTargetSection.targets(specific: false, text: "invalid"))
        XCTAssertThrowsError(try DeviceTargetSection.targets(specific: true, text: "\n  "))
        XCTAssertThrowsError(try DeviceTargetSection.targets(specific: true, text: "not-a-device"))
        XCTAssertEqual(try DeviceTargetSection.targets(specific: true, text: "192.168.1.42, ::1"), ["192.168.1.42", "::1"])
        let uuid = "12345678-abcd-1234-abcd-123456789abc"
        XCTAssertEqual(try DeviceTargetSection.targets(specific: true, text: " \(uuid)\n\n192.168.1.42\n::1\n"),
                       [uuid.uppercased(), "192.168.1.42", "::1"])
    }
}
