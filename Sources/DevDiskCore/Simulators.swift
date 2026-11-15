import Foundation

public struct SimDevice: Codable, Equatable, Sendable {
    public var udid: String
    public var name: String
    public var state: String
    public var runtime: String
    public var deviceType: String
    public var isAvailable: Bool
    public var dataBytes: Int64
    public var lastUsedAt: Date?

    public var isBooted: Bool { state == "Booted" }
    /// Devices devdisk created and may hand out. Anything else belongs to whoever made it.
    public var isPooled: Bool { name.hasPrefix(SimPlanner.poolPrefix) }
}

/// What a booted simulator costs right now.
public struct SimUsage: Codable, Equatable, Sendable {
    /// Sum of resident memory over the simulator's processes. Shared pages are counted
    /// once per process, so this overstates; it is still the right signal for "too many".
    public var residentBytes: Int64 = 0
    public var processes = 0
    public var bootedSeconds: TimeInterval = 0
}

public struct SimLimits: Sendable {
    /// Booted simulators allowed at once. A booted simulator runs a few hundred processes.
    public var maxBooted: Int
    /// `kern.memorystatus_level` (percent of memory available) required before another boot.
    public var minFreePercent = 20
    /// Pooled devices kept per device type and runtime.
    public var poolMax = 3
    public var leaseTTL: TimeInterval = 4 * 3600
    /// Unleased booted simulators are shut down after this long.
    public var idle: TimeInterval = 2 * 3600
    /// Shut-down temporary simulators are deleted after this long unused.
    public var tempAge: TimeInterval = 24 * 3600
    public var tempPattern = "(?i)(^|[-_ ])(te?mp)([-_ ]|$)"

    public init(memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let env = ProcessInfo.processInfo.environment["DEVDISK_MAX_BOOTED"].flatMap(Int.init)
        maxBooted = env ?? max(1, Int(memoryBytes >> 30) / 32)
    }
}

public struct ReapAction: Codable, Equatable, Sendable {
    public var udid: String
    public var name: String
    /// `shutdown` or `delete`.
    public var action: String
    public var reason: String
    public var bytes: Int64
    public var residentBytes: Int64
    public var outcome: String = "planned"
}

/// Pure decisions, kept apart from `simctl` so they can be tested.
public enum SimPlanner {
    public static let poolPrefix = "devdisk-"

    public enum Pick: Equatable {
        /// The owner already holds this device.
        case held(SimDevice)
        case reuse(SimDevice)
        case create(name: String)
        /// The pool is at its cap and every device is leased.
        case full(holders: [Lease])
    }

    public static func active(_ leases: [Lease], now: Date) -> [Lease] {
        leases.filter { $0.kind == "simulator" && $0.expiresAt > now }
    }

    public static func pick(devices: [SimDevice], leases: [Lease], owner: String, deviceType: String,
                            runtime: String, limits: SimLimits, now: Date) -> Pick {
        let live = active(leases, now: now)
        let pool = devices.filter { $0.isPooled && $0.isAvailable && $0.deviceType == deviceType && $0.runtime == runtime }
        if let mine = pool.first(where: { d in live.contains { $0.owner == owner && $0.id == d.udid } }) {
            return .held(mine)
        }
        let free = pool.filter { d in !live.contains { $0.id == d.udid } }
        // A booted free device is already warm; prefer it over booting another.
        if let device = free.first(where: \.isBooted) ?? free.first { return .reuse(device) }
        if pool.count >= limits.poolMax {
            return .full(holders: live.filter { lease in pool.contains { $0.udid == lease.id } })
        }
        let short = deviceType.split(separator: ".").last.map(String.init) ?? deviceType
        let taken = Set(devices.map(\.name))
        let name = (1...).lazy.map { "\(poolPrefix)\(short)-\($0)" }.first { !taken.contains($0) }!
        return .create(name: name)
    }

    /// Why another simulator may not boot now, or nil when it may.
    public static func bootRefusal(devices: [SimDevice], memoryLevel: Int?, limits: SimLimits) -> String? {
        let booted = devices.filter(\.isBooted).count
        if booted >= limits.maxBooted {
            return "\(booted) of \(limits.maxBooted) allowed simulators are already booted"
        }
        if let level = memoryLevel, level < limits.minFreePercent {
            return "only \(level)% of memory is available (need \(limits.minFreePercent)%)"
        }
        return nil
    }

    public static func reap(devices: [SimDevice], usage: [String: SimUsage], leases: [Lease],
                            limits: SimLimits, now: Date) -> [ReapAction] {
        let live = active(leases, now: now)
        let temp = try? NSRegularExpression(pattern: limits.tempPattern)
        return devices.compactMap { device in
            if live.contains(where: { $0.id == device.udid }) { return nil }
            let use = usage[device.udid] ?? SimUsage()
            func action(_ kind: String, _ reason: String) -> ReapAction {
                ReapAction(udid: device.udid, name: device.name, action: kind, reason: reason,
                           bytes: device.dataBytes, residentBytes: use.residentBytes)
            }
            if !device.isAvailable { return action("delete", "its runtime is not installed, so it cannot boot") }
            if device.isBooted {
                guard use.bootedSeconds >= limits.idle else { return nil }
                return action("shutdown", "booted \(formatDuration(use.bootedSeconds)) with no lease; data is kept")
            }
            let isTemp = temp?.firstMatch(in: device.name, range: NSRange(device.name.startIndex..., in: device.name)) != nil
            guard isTemp, device.state == "Shutdown" else { return nil }
            let unused = device.lastUsedAt.map { now.timeIntervalSince($0) } ?? .infinity
            guard unused >= limits.tempAge else { return nil }
            return action("delete", device.lastUsedAt == nil ? "temporary simulator that was never booted"
                                                             : "temporary simulator unused for \(formatDuration(unused))")
        }
    }

    /// Attributes processes to simulators by walking down from each `launchd_sim`.
    /// Input is the output of `ps -axo pid=,ppid=,rss=,etime=,command=`.
    public static func usage(psOutput: String) -> [String: SimUsage] {
        struct Row { var ppid: Int; var rss: Int64 }
        var rows: [Int: Row] = [:]
        var children: [Int: [Int]] = [:]
        var roots: [(pid: Int, udid: String, seconds: TimeInterval)] = []
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int(parts[0]), let ppid = Int(parts[1]), let rss = Int64(parts[2]) else { continue }
            rows[pid] = Row(ppid: ppid, rss: rss * 1024)
            children[ppid, default: []].append(pid)
            let command = parts[4]
            if command.hasPrefix("launchd_sim "), let range = command.range(of: "/Devices/") {
                roots.append((pid, String(command[range.upperBound...].prefix(36)), elapsedSeconds(String(parts[3]))))
            }
        }
        var result: [String: SimUsage] = [:]
        for root in roots {
            var use = SimUsage(bootedSeconds: root.seconds)
            var queue = [root.pid]
            var seen: Set<Int> = []
            while let pid = queue.popLast() {
                guard seen.insert(pid).inserted, let row = rows[pid] else { continue }
                use.residentBytes += row.rss
                use.processes += 1
                queue += children[pid] ?? []
            }
            result[root.udid] = use
        }
        return result
    }

    /// Parses ps `etime`: `[[dd-]hh:]mm:ss`.
    static func elapsedSeconds(_ text: String) -> TimeInterval {
        var days = 0.0
        var clock = Substring(text)
        if let dash = text.firstIndex(of: "-") {
            days = Double(text[..<dash]) ?? 0
            clock = text[text.index(after: dash)...]
        }
        let seconds = clock.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        return days * 86400 + seconds
    }
}

/// Everything that touches `simctl` and the running system.
enum SimHost {
    static func devices() -> [SimDevice] {
        guard let data = Shell.run("xcrun", ["simctl", "list", "devices", "-j"], timeout: 60).output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else { return [] }
        let iso = ISO8601DateFormatter()
        return runtimes.flatMap { runtime, list in
            list.compactMap { d -> SimDevice? in
                guard let udid = d["udid"] as? String else { return nil }
                return SimDevice(udid: udid, name: d["name"] as? String ?? udid, state: d["state"] as? String ?? "Unknown",
                                 runtime: runtime, deviceType: d["deviceTypeIdentifier"] as? String ?? "",
                                 isAvailable: d["isAvailable"] as? Bool ?? false,
                                 dataBytes: (d["dataPathSize"] as? NSNumber)?.int64Value ?? 0,
                                 lastUsedAt: (d["lastUsedAt"] as? String).flatMap(iso.date))
            }
        }.sorted { ($0.isBooted ? 0 : 1, $0.name) < ($1.isBooted ? 0 : 1, $1.name) }
    }

    static func usage() -> [String: SimUsage] {
        SimPlanner.usage(psOutput: Shell.run("/bin/ps", ["-axo", "pid=,ppid=,rss=,etime=,command="]).output)
    }

    /// Percent of memory the kernel considers available, the figure Activity Monitor's pressure graph follows.
    static func memoryLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? Int(level) : nil
    }

    /// Resolves a device type and runtime from loose names such as `iPhone 18 Pro` and `iOS 27.1`.
    /// Without a runtime, the newest installed one that supports the device type is used.
    static func resolve(deviceType: String, runtime: String?) -> (type: String, runtime: String)? {
        guard let data = Shell.run("xcrun", ["simctl", "list", "runtimes", "-j"], timeout: 60).output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["runtimes"] as? [[String: Any]] else { return nil }
        func matches(_ candidate: [String: Any], _ wanted: String) -> Bool {
            let id = candidate["identifier"] as? String ?? ""
            let name = candidate["name"] as? String ?? ""
            return name.caseInsensitiveCompare(wanted) == .orderedSame || id == wanted
                || id.lowercased().hasSuffix("." + wanted.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ".", with: "-"))
        }
        func version(_ r: [String: Any]) -> [Int] { (r["version"] as? String ?? "").split(separator: ".").map { Int($0) ?? 0 } }
        let usable = runtimes
            .filter { candidate in candidate["isAvailable"] as? Bool == true && (runtime.map { matches(candidate, $0) } ?? true) }
            .sorted { version($0).lexicographicallyPrecedes(version($1)) }
        for candidate in usable.reversed() {
            let types = candidate["supportedDeviceTypes"] as? [[String: Any]] ?? []
            if let type = types.first(where: { matches($0, deviceType) }),
               let typeID = type["identifier"] as? String, let runtimeID = candidate["identifier"] as? String {
                return (typeID, runtimeID)
            }
        }
        return nil
    }

    @discardableResult
    static func simctl(_ arguments: String...) -> ShellResult {
        Shell.run("xcrun", ["simctl"] + arguments, timeout: 300)
    }
}
