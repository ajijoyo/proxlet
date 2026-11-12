//
//  SystemTests.swift
//  ProxletCoreTests
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Crypto
import Foundation
@testable import ProxletCore
import XCTest

final class SystemTests: ProxletTestCase {
    func testPausedStoreRecordsNothing() {
        let store = FlowStore()
        let f = flow("https://x/")
        store.isRecording = false
        store.append(f)
        XCTAssertEqual(FlowStore.load().count, 0)
        store.append(f, force: true)
        XCTAssertEqual(FlowStore.load().count, 1, "imports are recorded while paused")
        store.isRecording = true
        store.append(f)
        XCTAssertEqual(FlowStore.load().count, 2)
    }

    func testDeleteFlowsRewritesFile() {
        let store = FlowStore()
        let flows = (0..<3).map { flow("https://x/\($0)") }
        flows.forEach { store.append($0) }
        store.delete(ids: [flows[0].id, flows[2].id])
        XCTAssertEqual(FlowStore.load().map(\.id), [flows[1].id])
        store.append(flows[0])
        XCTAssertEqual(FlowStore.load().count, 2)
    }

    func testSharedStateDefaultsRoundTripAndPrecision() throws {
        XCTAssertEqual(try SharedState.decoder.decode(SharedState.self, from: Data("{}".utf8)), SharedState())
        XCTAssertEqual(SharedState().port, SharedState.defaultPort)
        XCTAssertFalse(SharedState().noCaching, "No Caching is off until turned on, like Proxyman")

        SharedState.update { $0.mapLocal = false }
        SharedState.update { $0.recording = false }
        XCTAssertFalse(SharedState.load().mapLocal, "updating one field keeps the others")
        XCTAssertFalse(SharedState.load().recording)

        let first = SharedState.update { $0.clearedAt = Date() }.clearedAt
        let second = SharedState.update { $0.clearedAt = Date().addingTimeInterval(0.01) }.clearedAt
        let stored = try XCTUnwrap(SharedState.load().clearedAt).timeIntervalSince1970
        XCTAssertNotEqual(stored, try XCTUnwrap(first).timeIntervalSince1970, accuracy: 0.001, "sub-second clears are distinguishable")
        XCTAssertEqual(stored, try XCTUnwrap(second).timeIntervalSince1970, accuracy: 0.001)
    }

    func testScutilParsingMatchesExactPortAndHost() {
        let ours = "<dictionary> {\n  HTTPSEnable : 1\n  HTTPSPort : 9191\n  HTTPSProxy : 127.0.0.1\n}"
        XCTAssertTrue(SystemProxy.isEnabled(scutilOutput: ours, port: 9191))
        XCTAssertFalse(SystemProxy.isEnabled(scutilOutput: ours, port: 919), "port prefix must not match")
        let other = "  HTTPSEnable : 1\n  HTTPSPort : 19190\n  HTTPSProxy : 127.0.0.1\n"
        XCTAssertFalse(SystemProxy.isEnabled(scutilOutput: other, port: 1919))
        let remote = "  HTTPSEnable : 1\n  HTTPSPort : 9191\n  HTTPSProxy : 10.0.0.5\n"
        XCTAssertFalse(SystemProxy.isEnabled(scutilOutput: remote, port: 9191))
        XCTAssertFalse(SystemProxy.isEnabled(scutilOutput: "  HTTPSEnable : 0\n  HTTPSPort : 9191\n", port: 9191))
    }

    func testAdbProxyArguments() {
        XCTAssertEqual(AndroidEmulator.proxyArgs(serial: "emulator-5554", value: "10.0.2.2:9191"),
                       ["-s", "emulator-5554", "shell", "settings", "put", "global", "http_proxy", "10.0.2.2:9191"])
        XCTAssertEqual(AndroidEmulator.proxyArgs(serial: "e", value: ":0").last, ":0")
        let out = "List of devices attached\nemulator-5554\tdevice\nemulator-5556\toffline\nR58M12ABC\tdevice\n"
        XCTAssertEqual(AndroidEmulator.parseDevices(out), ["emulator-5554"])
    }

    func testFlowQueryFiltersCurlAndPaths() throws {
        let f = Flow(request: ProxyRequest(method: "POST", url: "https://api.example.com/v1/users?id=7",
                                           headers: [Header(name: "Content-Length", value: "11"), Header(name: "X-Q", value: "it's")],
                                           body: Data(#"{"a":"b'c"}"#.utf8)),
                     response: ProxyResponse(status: 201, headers: [], body: Data("created".utf8)),
                     startedAt: Date(), mocked: false, error: nil)
        func hit(_ key: String, _ matching: String, _ value: String, case cs: Bool = false) -> Bool {
            FlowQuery.matches(f, FlowQuery.Filter(key: key, matching: matching, value: value, caseSensitive: cs))
        }
        XCTAssertTrue(hit("host", "equal", "API.example.com"))
        XCTAssertFalse(hit("host", "equal", "API.example.com", case: true))
        XCTAssertTrue(hit("url", "wildcard", "*://api.*/v1/*"))
        XCTAssertTrue(hit("url", "regex", #"/v\d/users"#))
        XCTAssertTrue(hit("statusCode", "startWith", "20"))
        XCTAssertTrue(hit("requestHeader", "contains", "x-q: it's"))
        XCTAssertTrue(hit("responseBody", "notContains", "deleted"))
        XCTAssertTrue(hit("method", "notEqual", "GET"))
        XCTAssertTrue(hit("requestBody", "endWith", "}"))
        let both = [FlowQuery.Filter(key: "method", value: "POST"), FlowQuery.Filter(key: "host", value: "nope")]
        XCTAssertFalse(FlowQuery.matches(f, both, any: false))
        XCTAssertTrue(FlowQuery.matches(f, both, any: true))
        XCTAssertThrowsError(try FlowQuery.validate(FlowQuery.Filter(key: "hots", value: "x")))
        XCTAssertThrowsError(try FlowQuery.validate(FlowQuery.Filter(key: "host", matching: "like", value: "x")))

        let curl = FlowQuery.curl(f)
        XCTAssertTrue(curl.hasPrefix("curl -X POST 'https://api.example.com/v1/users?id=7'"))
        XCTAssertFalse(curl.contains("Content-Length"))
        XCTAssertTrue(curl.contains(#"-H 'X-Q: it'\''s'"#))
        XCTAssertTrue(curl.hasSuffix(#"--data-raw '{"a":"b'\''c"}'"#))

        XCTAssertEqual(FlowQuery.withSubpaths("https://a/api", true), "https://a/api*")
        XCTAssertEqual(FlowQuery.withSubpaths("https://a/api*", true), "https://a/api*")
        XCTAssertEqual(FlowQuery.withSubpaths("https://a/api*", false), "https://a/api")
        XCTAssertEqual(FlowQuery.withSubpaths("https://a/api*", nil), "https://a/api*")

        let dir = FlowQuery.exportURL(path: Paths.root.path, format: "har", now: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(dir.lastPathComponent, "Proxlet Session 42.har")
        XCTAssertEqual(FlowQuery.exportURL(path: "/tmp/x", format: "chls").lastPathComponent, "x.chls")
        XCTAssertEqual(FlowQuery.exportURL(path: "/tmp/x.har", format: "har").lastPathComponent, "x.har")
    }

    func testAppNameFromUserAgent() {
        XCTAssertEqual(Flow.appName(userAgent: "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Version/26.0 Safari/605.1.15"), "Safari")
        XCTAssertEqual(Flow.appName(userAgent: "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/141.0 Safari/537.36"), "Chrome")
        XCTAssertEqual(Flow.appName(userAgent: "acme/5.4.0 (iPhone; iOS 26.0) CFNetwork/3826 Darwin/25.0"), "acme")
        XCTAssertEqual(Flow.appName(userAgent: "My%20App/1 CFNetwork"), "My App")
        XCTAssertEqual(Flow.appName(userAgent: ""), "Unknown")
        let slack = "Mozilla/5.0 (Macintosh; Intel Mac OS X 26_5_1) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Slack/4.53.276 Chrome/156.0.8078.49 Electron/45.1.0 Safari/537.36 MacAppStore/25.5.0"
        XCTAssertEqual(Flow.appName(userAgent: slack), "Slack")
        let code = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Code/1.145.2 Chrome/150.0.7871.250 Electron/43.8.3 Safari/537.36"
        XCTAssertEqual(Flow.appName(userAgent: code), "Visual Studio Code")
    }

    func testAppFromExecutablePath() {
        let slackHelper = "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"
        XCTAssertEqual(ProcessLookup.appName(executablePath: slackHelper), "Slack")
        XCTAssertEqual(ProcessLookup.appName(executablePath: "/Applications/Dia.app/Contents/Frameworks/X.framework/Helpers/B.app/Contents/MacOS/B"), "Dia")
        XCTAssertNil(ProcessLookup.appName(executablePath: "/usr/bin/curl"))
    }

    func testSocketScanFindsOwnConnection() throws {
        // The runner must live inside an .app (e.g. Xcode.app) for its socket to resolve to an app name.
        try XCTSkipIf(ProcessLookup.appName(pid: getpid()) == nil, "test runner is not inside an .app bundle")
        let server = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(server) }
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                               sin_port: 0, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.bind(server, $0, len)
                _ = getsockname(server, $0, &len)
            }
        }
        Darwin.listen(server, 1)
        let serverPort = Int(UInt16(bigEndian: addr.sin_port))
        let client = try RawSocket(port: serverPort)
        let found = ProcessLookup.scan(proxyPort: serverPort)
        XCTAssertEqual(Set(found.values), [ProcessLookup.appName(pid: getpid())!])
        XCTAssertNotNil(ProcessLookup.listener(port: serverPort), "listening socket owner")
        _ = client
    }

    func testCAIsPersistedPrivatelyAndSignsLeaves() throws {
        let ca = try CertificateAuthority.loadOrCreate()
        let perms = try FileManager.default.attributesOfItem(atPath: Paths.caKey.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let reloaded = try CertificateAuthority.loadOrCreate()
        XCTAssertEqual(ca.certificate, reloaded.certificate)
        let leaf = try reloaded.leafCertificate(for: "api.example.com")
        XCTAssertEqual(leaf.issuer, ca.certificate.subject)
        XCTAssertTrue(ca.certificate.publicKey.isValidSignature(leaf.signature, for: leaf))
        XCTAssertNoThrow(try reloaded.serverContext(for: "api.example.com"))
    }

    func testCAValidityAppliesToNewCAAndRemoveRegenerates() throws {
        let first = try CertificateAuthority.loadOrCreate()
        let days = first.certificate.notValidAfter.timeIntervalSince(first.certificate.notValidBefore) / 86_400
        XCTAssertEqual(days, Double(CertificateAuthority.defaultValidityDays) + 1, accuracy: 0.01, "backdated by a day")
        XCTAssertEqual(try CertificateAuthority.loadOrCreate(validityDays: 30).certificate, first.certificate,
                       "an existing CA keeps its dates")

        try CertificateAuthority.remove()
        let second = try CertificateAuthority.loadOrCreate(validityDays: 30)
        XCTAssertNotEqual(second.certificate, first.certificate)
        XCTAssertEqual(second.certificate.notValidAfter.timeIntervalSinceNow / 86_400, 30, accuracy: 0.01)
        let leaf = try second.leafCertificate(for: "a.example")
        XCTAssertTrue(second.certificate.publicKey.isValidSignature(leaf.signature, for: leaf))
        XCTAssertEqual(leaf.notValidAfter, second.certificate.notValidAfter, "a leaf never outlives its CA")
        XCTAssertNoThrow(try CertificateAuthority.remove(), "removing twice is fine")
    }

    func testFlowLogRotatesAndClears() {
        let saved = FlowStore.maxFileSize
        FlowStore.maxFileSize = 200
        defer { FlowStore.maxFileSize = saved }
        let store = FlowStore()
        store.append(flow("https://a/1"))
        store.append(flow("https://a/2"))
        XCTAssertEqual(FlowStore.load().map(\.url), ["https://a/2"], "the full log moved to flows.1.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.root.appendingPathComponent("flows.1.jsonl").path))
        store.clear()
        XCTAssertTrue(FlowStore.load().isEmpty)
    }

    func testAppNamesForOtherBrowsersAndOddURLs() {
        XCTAssertEqual(Flow.appName(userAgent: "Mozilla/5.0 (Macintosh) AppleWebKit/537.36 Chrome/141 Safari/537.36 Edg/141.0"), "Edge")
        XCTAssertEqual(Flow.appName(userAgent: "Mozilla/5.0 (Macintosh; rv:140.0) Gecko/20100101 Firefox/140.0"), "Firefox")
        XCTAssertEqual(Flow.appName(userAgent: "Mozilla/5.0 (X11) Chrome/150 Electron/40 Safari/537.36"), "Electron",
                       "an Electron app without its own product token")
        XCTAssertEqual(Flow.appName(userAgent: "Mozilla/5.0 (compatible; bot)"), "Browser")
        let odd = flow("not a url")
        XCTAssertEqual(odd.host, "", "no host, so the flow stays out of the Domains tree")
        XCTAssertFalse(odd.path.isEmpty)
    }

    func testCAStatusReportsDatesFingerprintAndTrust() throws {
        XCTAssertNil(CertificateAuthority.status(), "no CA before the first start")
        let ca = try CertificateAuthority.loadOrCreate(validityDays: 30)
        let status = try XCTUnwrap(CertificateAuthority.status())
        XCTAssertTrue(status.subject.contains("Proxlet CA"), status.subject)
        XCTAssertEqual(status.notAfter, ca.certificate.notValidAfter)
        XCTAssertEqual(status.notAfter.timeIntervalSinceNow / 86_400, 30, accuracy: 0.01)

        let pem = try String(contentsOf: Paths.caCert, encoding: .utf8)
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(status.sha256, SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(), "fingerprint of the saved DER")
        XCTAssertEqual(status.sha256.count, 64)
        XCTAssertFalse(status.trusted, "a fresh CA is not in this Mac's keychain")
    }
}
