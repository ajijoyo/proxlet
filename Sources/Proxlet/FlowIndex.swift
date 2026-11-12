//
//  FlowIndex.swift
//  Proxlet
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import ProxletCore

/// Lookups the sidebar and flow list need on every render, rebuilt once per change of `AppModel.flows`.
struct FlowIndex {
    var byID: [Flow.ID: Flow] = [:]
    var byHost: [String: [Flow]] = [:]
    var hosts: [String] = []
    var byApp: [String: [Flow]] = [:]
    var apps: [String] = []
    /// Path tree per host for the sidebar; built here so a render never rebuilds it.
    var trees: [String: [PathNode]] = [:]

    init(_ flows: [Flow] = []) {
        byID = Dictionary(flows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        byHost = Dictionary(grouping: flows, by: \.host).filter { !$0.key.isEmpty }
        hosts = byHost.keys.sorted()
        byApp = Dictionary(grouping: flows, by: \.app)
        apps = byApp.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        trees = byHost.mapValues { flows in
            let scheme = flows.first?.url.hasPrefix("http://") == true ? "http" : "https"
            return PathNode.tree(host: flows[0].host, scheme: scheme, flows: flows)
        }
    }
}
