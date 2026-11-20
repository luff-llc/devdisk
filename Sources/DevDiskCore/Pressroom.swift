import Foundation

/// Live leases from pressroom, the gatekeeper that admits builds on this machine.
/// Read straight from its lease files (`pressroom.lease/1`), so no daemon is needed.
public struct PressroomLeases: Sendable {
    public struct Lease: Sendable {
        public var holder: String
        public var kind: String
        public var paths: [String]
    }

    public var leases: [Lease] = []
    /// Lease files that could not be read. Pressroom's contract says one of them might cover
    /// any path, so nothing is removed while one exists.
    public var unreadable: [String] = []

    public init(leases: [Lease] = [], unreadable: [String] = []) {
        self.leases = leases
        self.unreadable = unreadable
    }

    /// `$PRESSROOM_HOME` or `~/.pressroom`.
    public static func folder(home: URL) -> URL {
        if let dir = ProcessInfo.processInfo.environment["PRESSROOM_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return home.appendingPathComponent(".pressroom")
    }

    public static func load(from folder: URL, now: Date = Date()) -> PressroomLeases {
        var result = PressroomLeases()
        for file in Files.children(folder.path + "/leases") where file.hasSuffix(".json") {
            let name = (file as NSString).lastPathComponent
            guard let data = FileManager.default.contents(atPath: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["version"] as? String)?.hasPrefix("pressroom.lease/") == true,
                  let paths = object["paths"] as? [String], !paths.isEmpty,
                  paths.allSatisfy({ $0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }),
                  let expires = (object["expires"] as? NSNumber)?.doubleValue else {
                result.unreadable.append(name)
                continue
            }
            // Rule 10: live until its end, and only while its process exists.
            if expires < now.timeIntervalSince1970 { continue }
            if let pid = (object["pid"] as? NSNumber)?.int32Value, kill(pid, 0) != 0, errno == ESRCH { continue }
            result.leases.append(Lease(holder: object["holder"] as? String ?? "unknown",
                                       kind: object["kind"] as? String ?? "unknown", paths: paths))
        }
        return result
    }

    /// The lease covering `path`: one that names it, a folder around it, or something inside it.
    /// Compared without case, as on macOS.
    public func covering(_ path: String) -> Lease? {
        let target = path.lowercased()
        return leases.first { lease in
            lease.paths.contains { leased in
                let leased = leased.lowercased()
                return Files.contains(leased, target) || Files.contains(target, leased)
            }
        }
    }

    /// Why `path` must be left alone, or nil.
    public func refusal(_ path: String) -> String? {
        if let lease = covering(path) { return "leased by \(lease.holder) through pressroom (\(lease.kind))" }
        if !unreadable.isEmpty { return "pressroom lease file \(unreadable[0]) cannot be read, and it might cover this" }
        return nil
    }
}

/// Pressroom's own folders: warm build lanes, checkouts, scratch and results.
extension Rules {
    /// A lane untouched this long is cold enough to give back when space is short.
    static let pressroomLaneDays = 7

    static func pressroom(_ o: Options) -> [Finding] {
        let root = PressroomLeases.folder(home: o.home).path
        guard isDirectory(root) else { return [] }
        var candidates: [(path: String, label: String, days: Int)] = []
        // lanes/<repo>/<toolchain>/<n>: one warm build folder per parallel slot.
        for repo in Files.children(root + "/lanes") where isDirectory(repo) {
            for toolchain in Files.children(repo) where isDirectory(toolchain) {
                for slot in Files.children(toolchain) where isDirectory(slot) {
                    let name = "\((repo as NSString).lastPathComponent) \((toolchain as NSString).lastPathComponent) slot \((slot as NSString).lastPathComponent)"
                    candidates.append((slot, "pressroom build lane (\(name)); the next build there starts cold", pressroomLaneDays))
                }
            }
        }
        for folder in ["checkouts", "scratch", "results"] {
            for path in Files.children(root + "/" + folder) where isDirectory(path) {
                candidates.append((path, "pressroom \(folder.dropLast()) folder", pressroomLaneDays))
            }
        }
        let tool = pressroomTool()
        return parallelMap(candidates) { candidate in
            let age = Files.ageDays(candidate.path, now: o.now, depth: 2)
            // Pressroom decides first: leases and its own grace time.
            if let tool {
                let check = Shell.run(tool, ["may-delete", candidate.path], timeout: 10)
                if check.status != 0 {
                    let why = check.output.split(separator: "\n").first.map(String.init) ?? "pressroom says it must be kept"
                    return Finding(category: .caches, path: candidate.path, ageDays: age, tier: .info,
                                   reason: candidate.label + "; " + why, action: .none)
                }
            }
            let idle = (age ?? 0) >= candidate.days
            return Finding(category: .caches, path: candidate.path, ageDays: age, tier: idle ? .safe : .review,
                           reason: candidate.label + (idle ? ", untouched for \(age ?? 0) days" : ", used within \(candidate.days) days"),
                           action: .delete)
        }
    }

    /// The `pressroom` command, if installed.
    static func pressroomTool() -> String? {
        for path in ["/opt/homebrew/bin/pressroom", "/usr/local/bin/pressroom", NSHomeDirectory() + "/.local/bin/pressroom"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return nil
    }
}
