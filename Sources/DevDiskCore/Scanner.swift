import Foundation

public struct VolumeStatus: Codable, Sendable {
    public var totalBytes: Int64
    public var freeBytes: Int64
    /// `ok`, `low` (under 10% or 50 GB) or `critical` (under 5% or 20 GB).
    public var pressure: String

    public static func read(path: String = NSHomeDirectory()) -> VolumeStatus {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = max(values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeAvailableCapacity ?? 0))
        return VolumeStatus(totalBytes: total, freeBytes: free, pressure: pressure(total: total, free: free))
    }

    public static func pressure(total: Int64, free: Int64) -> String {
        let gb: Int64 = 1 << 30
        if free < 20 * gb || free * 20 < total { return "critical" }
        if free < 50 * gb || free * 10 < total { return "low" }
        return "ok"
    }
}

public struct ScanReport: Codable, Sendable {
    public var volume: VolumeStatus
    public var roots: [String]
    public var findings: [Finding]
    /// Bytes per tier, counting nested findings only once.
    public var totals: [String: Int64]
    /// Entries below `--min-size`, summed per category so nothing is hidden.
    public var belowMinimum: [String: Int64]
    /// How many sizes came from the cache instead of being measured in this run.
    public var sizesFromCache: Int
    public var seconds: Double
}

/// Set DEVDISK_TRACE=1 to print how long each phase takes.
func trace(_ message: String, since start: Date) {
    guard ProcessInfo.processInfo.environment["DEVDISK_TRACE"] != nil else { return }
    FileHandle.standardError.write(Data(String(format: "[%6.1fs] %@\n", Date().timeIntervalSince(start), message).utf8))
}

public enum Scanner {
    public static func scan(_ o: Options) -> ScanReport {
        let started = Date()
        let rules: [(Category, (Options) -> [Finding])] = [
            (.tmp, Rules.tmp), (.artifacts, Rules.artifacts), (.worktrees, Rules.worktrees), (.xcode, Rules.xcode),
            (.simulators, Rules.simulators), (.caches, Rules.caches), (.browsers, Rules.browsers),
            (.agents, Rules.agents), (.models, Rules.models), (.containers, Rules.containers),
        ].filter { o.categories.contains($0.0) }

        var findings = parallelMap(rules) { rule -> [Finding] in
            let ruleStart = Date()
            let found = rule.1(o)
            trace("rule \(rule.0.rawValue): \(found.count) candidates", since: ruleStart)
            return found
        }.flatMap { $0 }
        findings = Protection.apply(findings, o, activity: o.activity ?? Activity.current())

        var cache = o.sizeCache.map { SizeCache(url: $0, ttl: o.sizeCacheTTL) }
        var sizes: [String: Int64] = [:]
        var unmeasured: [String] = []
        for finding in findings where finding.bytes == 0 {
            if let bytes = cache?.lookup(finding.path, now: o.now) {
                sizes[finding.path] = bytes
            } else {
                unmeasured.append(finding.path)
            }
        }
        let fromCache = sizes.count
        let sizeStart = Date()
        let measured = Sizer.sizes(unmeasured)
        trace("measured \(unmeasured.count) paths", since: sizeStart)
        for (path, bytes) in measured {
            sizes[path] = bytes
            cache?.store(path, bytes: bytes, now: o.now)
        }
        cache?.save(now: o.now)
        var small: [String: Int64] = [:]
        findings = findings.compactMap { finding in
            var finding = finding
            if finding.bytes == 0 { finding.bytes = sizes[finding.path] ?? 0 }
            if finding.bytes < o.minBytes {
                small[finding.category.rawValue, default: 0] += finding.bytes
                return nil
            }
            return finding
        }
        findings.sort { $0.bytes > $1.bytes }

        return ScanReport(volume: .read(path: o.home.path), roots: o.roots.map(\.path), findings: findings,
                          totals: totals(findings), belowMinimum: small, sizesFromCache: fromCache,
                          seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10)
    }

    /// Sums bytes per tier, skipping findings that live inside another counted finding.
    static func totals(_ findings: [Finding]) -> [String: Int64] {
        var totals: [String: Int64] = [:]
        // Shortest paths first, so a parent is always counted before anything inside it.
        let sorted = findings.sorted { $0.path.count < $1.path.count }
        var counted: Set<String> = []
        for finding in sorted {
            var nested = counted.contains(finding.path)
            var cursor = Substring(finding.path)
            while !nested, let slash = cursor.lastIndex(of: "/"), slash > cursor.startIndex {
                cursor = cursor[..<slash]
                nested = counted.contains(String(cursor))
            }
            if nested { continue }
            counted.insert(finding.path)
            totals[finding.tier.rawValue, default: 0] += finding.bytes
        }
        return totals
    }
}
