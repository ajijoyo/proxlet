//
//  ProcessLookup.swift
//  ProxletCore
//
//  Created by Aji on 11/11/26
//  Copyright © 2026 Aji. Licensed under the MIT License.
//

import Darwin
import Foundation

/// Finds which local app opened a connection to the proxy, via the kernel's socket table (libproc).
public enum ProcessLookup {
    /// Client process behind a socket: its outermost `.app` and, for iOS simulator apps, the simulator's UDID.
    public struct Client: Sendable, Equatable {
        public var app: String?
        public var device: String?
    }

    private static let lock = NSLock()
    private static var cache: [Int: Client] = [:]
    private static let nameLock = NSLock()
    private static var names: [String: String] = [:]
    private static var lastScan = Date.distantPast
    /// Ephemeral client ports get reused, so a cached mapping is trusted only briefly.
    static let cacheLifetime: TimeInterval = 1

    /// Client owning the socket whose local port is `clientPort` and peer port is `proxyPort`.
    public static func client(clientPort: Int, proxyPort: Int) -> Client? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[clientPort], Date().timeIntervalSince(lastScan) < cacheLifetime { return hit }
        // One scan maps every client socket at once; back-to-back misses during a burst share a 50 ms spacing.
        let wait = 0.05 - Date().timeIntervalSince(lastScan)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        lastScan = Date()
        cache = scan(proxyPort: proxyPort)
        return cache[clientPort]
    }

    /// local port → client for all TCP sockets connected to `proxyPort`.
    static func scan(proxyPort: Int) -> [Int: Client] {
        var result: [Int: Client] = [:]
        for pid in allPIDs() {
            let sockets = tcpSockets(pid: pid).filter { $0.remote == proxyPort }
            guard !sockets.isEmpty, let path = executablePath(pid: pid) else { continue }
            let client = Client(app: appName(executablePath: path), device: simulatorDevice(executablePath: path))
            guard client.app != nil || client.device != nil else { continue }
            for socket in sockets { result[socket.local] = client }
        }
        return result
    }

    /// Process listening on `port`, e.g. to explain why the proxy could not start.
    public static func listener(port: Int) -> String? {
        for pid in allPIDs() {
            guard tcpSockets(pid: pid).contains(where: { $0.local == port && $0.remote == 0 }) else { continue }
            if let app = appName(pid: pid) { return app }
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            return "\(String(cString: name)) (pid \(pid))"
        }
        return nil
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)  // headroom for processes started meanwhile
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(n, 0))).filter { $0 > 0 }
    }

    private static func tcpSockets(pid: pid_t) -> [(local: Int, remote: Int)] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let fdCount = Int(size) / MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard filled > 0 else { return [] }
        var sockets: [(local: Int, remote: Int)] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard got == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            let remote = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)))
            sockets.append((local, remote))
        }
        return sockets
    }

    /// Outermost `.app` name for the process (helpers resolve to their parent app), else nil.
    static func appName(pid: pid_t) -> String? {
        executablePath(pid: pid).flatMap(appName(executablePath:))
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// UDID from `.../CoreSimulator/Devices/<UDID>/...`, uppercased; nil outside a simulator.
    static func simulatorDevice(executablePath path: String) -> String? {
        guard let range = path.range(of: "/CoreSimulator/Devices/") else { return nil }
        let udid = path[range.upperBound...].prefix { $0 != "/" }
        return UUID(uuidString: String(udid)) != nil ? udid.uppercased() : nil
    }

    /// Simulator name from its `device.plist` (e.g. "iPhone 17"), cached; nil when the simulator is gone.
    public static func simulatorName(udid: String, root: URL = simulatorRoot) -> String? {
        nameLock.lock()
        defer { nameLock.unlock() }
        let key = root.path + "/" + udid
        if let hit = names[key] { return hit }
        let url = root.appendingPathComponent(udid).appendingPathComponent("device.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["name"] as? String else { return nil }
        names[key] = name
        return name
    }

    public static let simulatorRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/CoreSimulator/Devices")

    static func appName(executablePath path: String) -> String? {
        if let app = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        // System daemons (e.g. WebKit networking) have no app bundle; callers fall back to User-Agent.
        return nil
    }
}
