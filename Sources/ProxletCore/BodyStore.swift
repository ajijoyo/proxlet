//
//  BodyStore.swift
//  ProxletCore
//
//  Created by Aji on 12/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Raw image response bodies in `bodies/<flow-id>`; flows.jsonl only keeps text.
public enum BodyStore {
    static let maxImage = 10_000_000

    static func file(_ flowID: String) -> URL {
        Paths.root.appendingPathComponent("bodies", isDirectory: true).appendingPathComponent(flowID)
    }

    static func isImage(_ headers: [Header]) -> Bool {
        headers.first { $0.name.lowercased() == "content-type" }?.value.lowercased().hasPrefix("image/") ?? false
    }

    /// Keeps `body` when the flow's response is an image of at most 10 MB.
    static func saveIfImage(_ body: Data, for flow: Flow) {
        guard !body.isEmpty, body.count <= maxImage, isImage(flow.responseHeaders) else { return }
        let url = file(flow.id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? body.write(to: url)
    }

    public static func load(flowID: String) -> Data? {
        try? Data(contentsOf: file(flowID))
    }

    public static func delete(flowIDs: Set<String>) {
        for id in flowIDs { try? FileManager.default.removeItem(at: file(id)) }
    }
}
