//
//  BodyImageTests.swift
//  ProxletTests
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
@testable import Proxlet
import XCTest

final class BodyImageTests: XCTestCase {
    func testDecodesImagesAndDescribesThem() throws {
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))
        let image = try XCTUnwrap(BodyImage(png))
        XCTAssertTrue(image.caption.hasPrefix("1×1 px · "), image.caption)
        XCTAssertNil(BodyImage(Data("not an image".utf8)))
    }
}
