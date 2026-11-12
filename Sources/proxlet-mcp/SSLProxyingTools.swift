//
//  SSLProxyingTools.swift
//  proxlet-mcp
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import ProxletCore

func sslList(_ a: Args) throws -> SSLProxying.List {
    guard let raw = a.str("list") else { return .include }
    guard let list = SSLProxying.List(rawValue: raw) else { throw ToolError(message: "list must be include or exclude") }
    return list
}

func enableSSLProxying(_ a: Args) throws -> String {
    let domain = try a.required("domain")
    var added = false
    try SSLProxying.update { added = $0.add(domain) }
    guard added else { throw ToolError(message: "\(domain) is not a host or *.host pattern") }
    return "SSL Proxying enabled for \(SSLProxying.normalize(domain) ?? domain)"
}

func disableSSLProxying(_ a: Args) throws -> String {
    let (domain, list) = (try a.required("domain"), try sslList(a))
    var removed = false
    try SSLProxying.update { removed = $0.remove(domain, from: list) }
    guard removed else { throw ToolError(message: "\(domain) is not in the \(list.rawValue) list") }
    return "Removed \(domain) from the \(list.rawValue) list"
}

func getSSLProxyingList(_: Args) throws -> String {
    let s = SSLProxying.load()
    func rows(_ entries: [SSLProxying.Entry]) -> [[String: Any]] { entries.map { ["domain": $0.domain, "enabled": $0.enabled] } }
    return try json(any: ["include": rows(s.include), "exclude": rows(s.exclude),
                          "note": "Only hosts matching an enabled include entry (and no enabled exclude entry) are decrypted."])
}

func toggleSSLProxyingDomain(_ a: Args) throws -> String {
    let (domain, list) = (try a.required("domain"), try sslList(a))
    guard let enabled = a.bool("enabled") else { throw ToolError(message: "Missing argument enabled") }
    var found = false
    try SSLProxying.update { found = $0.setEnabled(enabled, domain: domain, list: list) }
    guard found else { throw ToolError(message: "\(domain) is not in the \(list.rawValue) list; add it with enable_ssl_proxying") }
    return "\(domain) \(enabled ? "enabled" : "disabled") in the \(list.rawValue) list"
}
