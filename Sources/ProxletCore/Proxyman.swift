//
//  Proxyman.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation

/// Import/export of the Map Local rule tree and scripting `.config` formats.
public enum Proxyman {
    /// Rule tree (`{"nodes"|"tree": [{"nodeType": {"node": {"_0": rule}} | {"folder": …}}]}`), shared by
    /// the Map Local and Scripting importers.
    enum RuleTree {
        /// Every rule dict (`node._0`), with folders flattened.
        static func rules(_ nodes: [[String: Any]]) -> [[String: Any]] {
            nodes.flatMap { node -> [[String: Any]] in
                guard let type = node["nodeType"] as? [String: Any] else { return [] }
                if let folder = type["folder"] as? [String: Any],
                   let children = folder["nodes"] as? [[String: Any]] ?? (folder["_0"] as? [String: Any])?["nodes"] as? [[String: Any]] {
                    return rules(children)
                }
                return ((type["node"] as? [String: Any])?["_0"] as? [String: Any]).map { [$0] } ?? []
            }
        }

        /// `method: {"exact": [{"name": "GET"}]}` → "GET"; `{"any": {}}` → nil.
        static func method(_ rule: [String: Any]) -> String? {
            ((rule["method"] as? [String: Any])?["exact"] as? [[String: Any]])?.first?["name"] as? String
        }
    }

    /// `MapLocalFiles-RuleTree`: `{"nodes":[{"nodeType":{"node":{"_0":{name,url,regex,method,isEnabled,localFile:{path}}}}}]}`
    /// Picking the wrong kind of export in an import dialog.
    public struct WrongKind: LocalizedError {
        public let errorDescription: String?
    }

    /// Scripting rules carry their code; Map Local rules point at a local file.
    static func isScript(_ rule: [String: Any]) -> Bool { rule["fileContent"] != nil || rule["isEnableRequest"] != nil }

    /// Also a rule export (`.config`): a bare node array, maybe gzipped, with each body embedded as base64 `importFileData`.
    static func mapLocalRules(_ data: Data) throws -> [MockRule]? {
        let json = data.starts(with: [0x1f, 0x8b]) ? (ContentDecoding.gunzip(data) ?? Data()) : data
        let root = try? JSONSerialization.jsonObject(with: json)
        let dict = root as? [String: Any]
        guard let nodes = root as? [[String: Any]] ?? dict?["nodes"] as? [[String: Any]] ?? dict?["tree"] as? [[String: Any]]
        else { return nil }
        let rules = RuleTree.rules(nodes)
        if !rules.isEmpty, rules.allSatisfy(isScript) {
            throw WrongKind(errorDescription: "This file has scripts, not Map Local rules. Import it from the Scripts page.")
        }
        return rules.filter { !isScript($0) }.compactMap { r in
            guard let url = r["url"] as? String else { return nil }
            let file = r["localFile"] as? [String: Any]
            let path = file?["path"] as? String
            // The embedded copy travels with the export; the path only exists on the exporting Mac.
            let embedded = (file?["importFileData"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) }
            let text = embedded ?? path.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            let message = text.map { HTTPMessageFormat.parseFile($0, pathExtension: ((path ?? "") as NSString).pathExtension) }
            return MockRule(name: r["name"] as? String ?? "", enabled: r["isEnabled"] as? Bool ?? true,
                            method: RuleTree.method(r), urlPattern: url, useRegex: (r["regex"] as? String) == "useRegex",
                            status: message?.status ?? 200, headers: message?.headers ?? [:], body: message?.body ?? "")
        }
    }

    /// Scripting export (`*.config`): gzip-compressed JSON
    /// `{"tree":[{"nodeType":{"node":{"_0":{name,url,regex,method,isEnabled,isEnableRequest,isEnableResponse,fileContent,…}}}}],"userFiles":[…]}`.
    public enum ScriptConfig {
        public struct Imported {
            public var fileName: String
            public var source: String
        }

        public struct Result {
            public var scripts: [Imported]
            /// Things Proxlet can't reproduce, e.g. "Run as Mock API" or shared user files.
            public var notes: [String]
        }

        public struct FormatError: LocalizedError {
            public var errorDescription: String? { "This file has no scripts Proxlet can read." }
        }

        public static func importConfig(_ data: Data, existing: Set<String> = []) throws -> Result {
            let json = data.starts(with: [0x1f, 0x8b]) ? (ContentDecoding.gunzip(data) ?? Data()) : data
            let parsed = try? JSONSerialization.jsonObject(with: json)
            let mapLocal = WrongKind(errorDescription: "This file has Map Local rules, not scripts. Import it from the Map Local page.")
            if let nodes = parsed as? [[String: Any]] ?? (parsed as? [String: Any])?["nodes"] as? [[String: Any]],
               !RuleTree.rules(nodes).isEmpty { throw mapLocal }
            guard let root = parsed as? [String: Any], let tree = root["tree"] as? [[String: Any]] else { throw FormatError() }
            let found = RuleTree.rules(tree)
            if !found.isEmpty, !found.contains(where: isScript) { throw mapLocal }
            var used = existing
            var scripts: [Imported] = []
            var mockAPI: [String] = []
            for r in found {
                var meta = ScriptMeta()
                meta.name = r["name"] as? String ?? "Imported Script"
                meta.enabled = r["isEnabled"] as? Bool ?? true
                meta.match = r["url"] as? String ?? ""
                meta.useRegex = (r["regex"] as? String) == "useRegex"
                meta.method = RuleTree.method(r)
                meta.onRequest = r["isEnableRequest"] as? Bool ?? true
                meta.onResponse = r["isEnableResponse"] as? Bool ?? true
                if r["isMockResponse"] as? Bool == true { mockAPI.append(meta.name) }
                let code = r["fileContent"] as? String ?? ""
                let name = ScriptStore.uniqueFileName(for: meta.name, used: &used)
                scripts.append(Imported(fileName: name, source: meta.render(code: code)))
            }
            var notes: [String] = []
            if !mockAPI.isEmpty {
                notes.append("\"Run as Mock API\" isn't supported yet; these run on the real response instead: \(mockAPI.joined(separator: ", ")).")
            }
            if let files = root["userFiles"] as? [[String: Any]], !files.isEmpty {
                let names = files.compactMap { $0["name"] as? String }.joined(separator: ", ")
                notes.append("Shared user files (require(\"@users/…\")) were not imported: \(names).")
            }
            return Result(scripts: scripts, notes: notes)
        }

        /// `.config` export from script files.
        public static func exportConfig(_ files: [URL]) throws -> Data {
            let nodes: [[String: Any]] = try files.map { url in
                let (meta, code) = ScriptMeta.parse(try String(contentsOf: url, encoding: .utf8))
                let rule: [String: Any] = [
                    "id": String(UUID().uuidString.prefix(8)),
                    "name": meta.name.isEmpty ? url.deletingPathExtension().lastPathComponent : meta.name,
                    "url": meta.match.isEmpty ? "*" : meta.match,
                    "regex": meta.useRegex ? "useRegex" : "useWildcard",
                    "method": meta.method.map { ["exact": [["name": $0]]] } ?? ["any": [String: Any]()],
                    "isEnabled": meta.enabled,
                    "isEnableRequest": meta.onRequest,
                    "isEnableResponse": meta.onResponse,
                    "isMockResponse": false,
                    "isIncludingPaths": false,
                    "graphQLQueryName": NSNull(),
                    "filePath": "",
                    "fileContent": code,
                ]
                return ["nodeType": ["node": ["_0": rule]]]
            }
            let json = try JSONSerialization.data(withJSONObject: ["tree": nodes, "entries": NSNull(), "userFiles": []],
                                                  options: [.withoutEscapingSlashes])
            guard let gz = ContentDecoding.gzip(json) else { throw FormatError() }
            return gz
        }
    }
}
