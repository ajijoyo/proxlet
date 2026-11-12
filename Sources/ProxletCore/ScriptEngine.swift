//
//  ScriptEngine.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Foundation
import JavaScriptCore

/// Runs every enabled `scripts/*.js` file in name order.
/// A script may define `onRequest(req)` and/or `onResponse(req, res)` and return the (modified) object.
/// `req = {method, url, headers: {name: value}, body}`, `res = {status, headers, body}`.
public final class ScriptEngine: @unchecked Sendable {
    /// Result of running every matching script on one phase.
    public struct Outcome<Value> {
        public var value: Value
        public var errors: [String]
        /// Script files that returned a change.
        public var applied: [String]
    }

    private struct Loaded {
        let modified: Date
        let context: JSContext
        let meta: ScriptMeta
        /// Syntax error from loading the file; reported on every match instead of skipping the script silently.
        let loadError: String?
        /// A JSContext is single-threaded; each script has its own lock so a slow one only delays its own matches.
        let runLock = NSLock()
    }

    private var cache: [String: Loaded] = [:]
    /// Guards `cache` only; never held while JS runs.
    private let cacheLock = NSLock()
    /// Seconds a single script call (or load) may run before JavaScriptCore terminates it.
    static let timeLimit: Double = 2

    // JSContextGroupSetExecutionTimeLimit is exported by JavaScriptCore but not in the public headers.
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
    private static let setLimit: SetLimit? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit")
        .map { unsafeBitCast($0, to: SetLimit.self) }

    public init() {}

    // Two-argument scripts take (req[, res]); four-argument ones take (context, url, request[, response]),
    // detected by arity, and get objects with statusCode and a parsed JSON body.
    private static let runner = """
    var console = { log: function () {}, error: function () {}, warn: function () {} };
    function __proxlet_parse(body) { try { return JSON.parse(body); } catch (e) { return body; } }
    function __proxlet_text(body) { return (typeof body === 'string') ? body : JSON.stringify(body); }
    function __proxlet_run(name, a, b) {
      var f = globalThis[name];
      if (typeof f !== 'function') return null;
      var req = JSON.parse(a), res = b ? JSON.parse(b) : undefined, r;
      if (f.length >= 3) {
        var u = req._parts || {};
        var preq = { method: req.method, url: req.url, scheme: u.scheme, host: u.host, port: u.port, path: u.path,
                     queryString: u.query || {}, headers: req.headers, body: __proxlet_parse(req.body) };
        if (name === 'onRequest') {
          r = f({}, req.url, preq);
          if (r) r = { method: r.method, url: r.url, headers: r.headers, body: __proxlet_text(r.body) };
        } else {
          r = f({}, req.url, preq, { statusCode: res.status, headers: res.headers, body: __proxlet_parse(res.body) });
          if (r) r = { status: r.statusCode, headers: r.headers, body: __proxlet_text(r.body) };
        }
      } else {
        r = f(req, res);
      }
      return (r === undefined || r === null) ? null : JSON.stringify(r);
    }
    """

    /// Whether any script would run for this request (on either phase).
    public func hasMatch(method: String, url: String) -> Bool {
        contexts().contains { _, loaded in
            (loaded.meta.onRequest || loaded.meta.onResponse) && loaded.meta.matches(method: method, url: url)
        }
    }

    public func onRequest(_ req: ProxyRequest) -> Outcome<ProxyRequest> {
        var out = req
        var errors: [String] = []
        var applied: [String] = []
        for (name, loaded) in contexts() where loaded.meta.onRequest && loaded.meta.matches(method: out.method, url: out.url) {
            do {
                guard let json = try run(loaded, "onRequest", Self.encode(req: out)) else { continue }
                Self.apply(json, to: &out)
                applied.append(name)
            } catch {
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        return Outcome(value: out, errors: errors, applied: applied)
    }

    public func onResponse(_ req: ProxyRequest, _ res: ProxyResponse) -> Outcome<ProxyResponse> {
        var out = res
        var errors: [String] = []
        var applied: [String] = []
        for (name, loaded) in contexts() where loaded.meta.onResponse && loaded.meta.matches(method: req.method, url: req.url) {
            do {
                guard let json = try run(loaded, "onResponse", Self.encode(req: req), Self.encode(res: out)) else { continue }
                Self.apply(json, to: &out)
                applied.append(name)
            } catch {
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        return Outcome(value: out, errors: errors, applied: applied)
    }

    // MARK: - JS plumbing

    private struct ScriptError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Reloads a script only when its file modification date changes.
    private func contexts() -> [(String, Loaded)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Paths.scripts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var result: [(String, Loaded)] = []
        var seen = Set<String>()
        for url in files.filter({ $0.pathExtension == "js" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            seen.insert(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let hit = cache[name], hit.modified == modified {
                result.append((name, hit))
                continue
            }
            guard let source = try? String(contentsOf: url, encoding: .utf8), let ctx = JSContext() else { continue }
            Self.setLimit?(JSContextGetGroup(ctx.jsGlobalContextRef), Self.timeLimit, nil, nil)
            ctx.evaluateScript(Self.runner)
            ctx.evaluateScript(source, withSourceURL: url)
            let loadError = ctx.exception.map { "failed to load: \($0)" }
            ctx.exception = nil
            let loaded = Loaded(modified: modified, context: ctx, meta: ScriptMeta.parse(source).0, loadError: loadError)
            cache[name] = loaded
            result.append((name, loaded))
        }
        cache = cache.filter { seen.contains($0.key) }
        return result
    }

    private func run(_ loaded: Loaded, _ fn: String, _ args: String...) throws -> [String: Any]? {
        if let loadError = loaded.loadError { throw ScriptError(message: loadError) }
        loaded.runLock.lock()
        defer { loaded.runLock.unlock() }
        let ctx = loaded.context
        let value = ctx.objectForKeyedSubscript("__proxlet_run")?.call(withArguments: [fn] + args)
        if let exc = ctx.exception {
            ctx.exception = nil
            throw ScriptError(message: "\(fn): \(exc)")
        }
        guard let value, value.isString, let s = value.toString(), let data = s.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func headerDict(_ headers: [Header]) -> [String: String] {
        Dictionary(headers.map { ($0.name, $0.value) }, uniquingKeysWith: { a, b in "\(a), \(b)" })
    }

    static func encode(req: ProxyRequest) -> String {
        let c = URLComponents(string: req.url)
        var query: [String: String] = [:]
        for item in c?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        // `_parts` feeds four-argument scripts (JavaScriptCore has no URL API).
        let parts: [String: Any] = ["scheme": c?.scheme ?? "", "host": c?.host ?? "", "port": c?.port ?? 0,
                                    "path": c?.path ?? "", "query": query]
        return json(["method": req.method, "url": req.url, "headers": headerDict(req.headers),
                     "body": String(data: req.body, encoding: .utf8) ?? "", "_parts": parts])
    }

    static func encode(res: ProxyResponse) -> String {
        json(["status": res.status, "headers": headerDict(res.headers),
              "body": String(data: res.body, encoding: .utf8) ?? ""])
    }

    static func json(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// Headers returned by a script. Names whose value is unchanged keep their original lines,
    /// so duplicates such as two `Set-Cookie` headers survive a round-trip through the `{name: value}` object.
    static func headers(from obj: Any?, original: [Header]) -> [Header]? {
        guard let dict = obj as? [String: Any] else { return nil }
        let before = headerDict(original)
        var out: [Header] = []
        for (name, value) in dict {
            let text = "\(value)"
            if before[name] == text {
                out += original.filter { $0.name == name }
            } else {
                out.append(Header(name: name, value: text))
            }
        }
        // Keep the original order for untouched headers.
        let order = Dictionary(original.enumerated().map { ($0.element.name, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return out.enumerated().sorted { (order[$0.element.name] ?? Int.max, $0.offset) < (order[$1.element.name] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// A returned body may be a string or a JSON value (object/array).
    static func bodyText(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        guard let any, !(any is NSNull), JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func apply(_ obj: [String: Any], to req: inout ProxyRequest) {
        if let m = obj["method"] as? String { req.method = m }
        if let u = obj["url"] as? String { req.url = u }
        if let h = headers(from: obj["headers"], original: req.headers) { req.headers = h }
        if let b = bodyText(obj["body"]), b != (String(data: req.body, encoding: .utf8) ?? "") { req.body = Data(b.utf8) }
    }

    static func apply(_ obj: [String: Any], to res: inout ProxyResponse) {
        if let s = (obj["status"] as? Int) ?? (obj["statusCode"] as? Int) { res.status = s }
        if let h = headers(from: obj["headers"], original: res.headers) { res.headers = h }
        if let b = bodyText(obj["body"]), b != (String(data: res.body, encoding: .utf8) ?? "") { res.body = Data(b.utf8) }
    }
}
