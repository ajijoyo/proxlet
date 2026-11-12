//
//  JSONFormatter.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

public enum JSONFormatter {
    /// Pretty-printed JSON, or nil when the body isn't a JSON object or array.
    public static func pretty(_ body: String) -> String? {
        guard let first = body.first(where: { !$0.isWhitespace }), first == "{" || first == "[",
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: out, encoding: .utf8)
    }
}
