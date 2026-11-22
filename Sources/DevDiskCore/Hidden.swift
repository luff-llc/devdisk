import Foundation

/// Space that no scan can see: what APFS says the Data volume holds, minus everything this user
/// can read. The gap lives in folders only root can open (Spotlight's index, the Versions store,
/// system logs), in local snapshots, and in other users' files.
public struct HiddenReport: Codable, Sendable {
    public struct Folder: Codable, Sendable {
        public var path: String
        public var measuredBytes: Int64
        /// Folders inside it that could not be opened, largest suspects first.
        public var unreadable: [String]
    }

    public struct Suspect: Codable, Sendable {
        public var path: String
        public var what: String
        /// How to measure it (needs an administrator password).
        public var measure: String
        /// How to give the space back, if it turns out to be large.
        public var fix: String
    }

    public struct Spotlight: Codable, Sendable {
        /// `mdutil -s` per volume: whether indexing is on.
        public var volumes: [String: String]
        /// The index server's resident memory and CPU, a sign of an index that keeps rebuilding.
        public var storesResidentBytes: Int64
        public var storesCPUPercent: Double
        /// Per-app indexes in ~/Library/Metadata/CoreSpotlight, readable without a password.
        public var appIndexesBytes: Int64
    }

    public var volume: String
    /// Bytes APFS reports in use on the volume.
    public var inUseBytes: Int64
    /// Bytes measured in folders this user can read. APFS clones count once per copy here, so
    /// this can overstate, and the gap is then a lower bound.
    public var measuredBytes: Int64
    public var gapBytes: Int64
    public var folders: [Folder]
    public var snapshots: [String]
    public var spotlight: Spotlight
    public var suspects: [Suspect]
    /// One command that measures every unreadable folder found, for the user to run.
    public var measureCommand: String
    public var seconds: Double
}

public enum Hidden {
    public static let dataVolume = "/System/Volumes/Data"

    static let knownSuspects: [(String, String, String)] = [
        (".Spotlight-V100", "Spotlight's index for this volume. A broken index can grow to tens or hundreds of GB.",
         "sudo mdutil -E / rebuilds it from scratch (search is slow for an hour or so while it reindexes)"),
        (".DocumentRevisions-V100", "the Versions store: earlier versions of documents saved by apps",
         "shrinks as apps prune; large values usually mean an app saving huge documents repeatedly"),
        (".fseventsd", "the file-change log Spotlight and Time Machine read", "rarely large; removed and rebuilt by macOS on reboot if deleted as root"),
        ("private/var/db/diagnostics", "unified system logs", "sudo log erase --all"),
        ("private/var/db/uuidtext", "symbol data for the system logs", "pruned with the logs"),
        ("Library/Caches", "system-wide caches", "mostly regenerable; inspect with sudo du"),
        ("private/var/folders", "per-user temporary and cache folders, including other users'", "reboot clears much of it"),
        ("Library/Updates", "downloaded macOS updates", "install or delete them in Software Update"),
    ]

    public static func report(volume: String = dataVolume) -> HiddenReport {
        let started = Date()
        let inUse = capacityInUse(volume)
        // Every top-level folder is walked on its own thread; unreadable folders are collected.
        let tops = Files.children(volume).filter { isDirectory($0) && !Files.isSymlink($0) && !$0.hasSuffix("/Volumes") }
        let measured = parallelMap(tops, width: 8) { Walker.measure($0, recordUnreadable: true) }
        var folders: [HiddenReport.Folder] = []
        for (path, m) in zip(tops, measured) {
            folders.append(HiddenReport.Folder(path: path, measuredBytes: m.total, unreadable: collapse(m.unreadable)))
        }
        // Files directly at the top of the volume.
        let topFiles = Files.children(volume).filter { !isDirectory($0) }.reduce(Int64(0)) { sum, path in
            var info = stat()
            return lstat(path, &info) == 0 ? sum + Int64(info.st_blocks) * 512 : sum
        }
        folders.sort { $0.measuredBytes > $1.measuredBytes }
        let measuredTotal = folders.reduce(topFiles) { $0 + $1.measuredBytes }
        let unreadable = folders.flatMap(\.unreadable)

        let suspects = knownSuspects.compactMap { relative, what, fix -> HiddenReport.Suspect? in
            let path = volume + "/" + relative
            guard FileManager.default.fileExists(atPath: path),
                  unreadable.contains(where: { Files.contains($0, path) || Files.contains(path, $0) }) else { return nil }
            return HiddenReport.Suspect(path: path, what: what, measure: "sudo du -sh '\(path)'", fix: fix)
        }
        let snapshots = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30).output
            .split(separator: "\n").map(String.init).filter { $0.hasPrefix("com.apple") }
        let topUnreadable = unreadable.filter { $0.split(separator: "/").count <= 6 }.prefix(40)
        let command = topUnreadable.isEmpty ? "" : "sudo du -shx " + topUnreadable.map { "'\($0)'" }.joined(separator: " ") + " 2>/dev/null | sort -h"
        return HiddenReport(volume: volume, inUseBytes: inUse, measuredBytes: measuredTotal, gapBytes: inUse - measuredTotal,
                            folders: folders, snapshots: snapshots, spotlight: spotlight(), suspects: suspects,
                            measureCommand: command, seconds: (Date().timeIntervalSince(started) * 10).rounded() / 10)
    }

    /// Keeps the outermost unreadable folders; anything inside one is already covered by it.
    static func collapse(_ paths: [String]) -> [String] {
        let sorted = paths.sorted { $0.count < $1.count }
        var kept: [String] = []
        for path in sorted where !kept.contains(where: { Files.contains($0, path) }) { kept.append(path) }
        return kept
    }

    static func capacityInUse(_ volume: String) -> Int64 {
        let out = Shell.run("/usr/sbin/diskutil", ["info", "-plist", volume], timeout: 30).output
        guard let data = out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return 0 }
        return (plist["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
    }

    static func spotlight() -> HiddenReport.Spotlight {
        var volumes: [String: String] = [:]
        let status = Shell.run("/usr/bin/mdutil", ["-s", "/", dataVolume], timeout: 30).output
        var current = ""
        for line in status.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(":") { current = String(text.dropLast()) } else if !current.isEmpty { volumes[current] = text }
        }
        var rss: Int64 = 0, cpu = 0.0
        for line in Shell.run("/bin/ps", ["-axo", "rss=,%cpu=,comm="], timeout: 30).output.split(separator: "\n")
        where line.hasSuffix("/mds_stores") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 { rss += (Int64(parts[0]) ?? 0) * 1024; cpu += Double(parts[1]) ?? 0 }
        }
        let appIndexes = Walker.measure(NSHomeDirectory() + "/Library/Metadata/CoreSpotlight").total
        return HiddenReport.Spotlight(volumes: volumes, storesResidentBytes: rss, storesCPUPercent: cpu, appIndexesBytes: appIndexes)
    }
}
