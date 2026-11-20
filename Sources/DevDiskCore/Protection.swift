import Foundation

/// A snapshot of what is running, taken once per scan.
public struct Activity: Sendable {
    /// Full command lines of running processes.
    public var commands: [String]
    /// Working directories of this user's running processes.
    public var workingDirectories: [String]
    /// Paths named by this user's LaunchAgents: jobs that run on a timer and so may not be
    /// running at the moment of the scan.
    public var scheduled: [String]

    public init(commands: [String] = [], workingDirectories: [String] = [], scheduled: [String] = []) {
        self.commands = commands
        self.workingDirectories = workingDirectories
        self.scheduled = scheduled
    }

    static func current(home: URL) -> Activity {
        let commands = Shell.run("/bin/ps", ["-axo", "command="], timeout: 30).output
            .split(separator: "\n").map(String.init)
        return Activity(commands: commands, workingDirectories: Files.activeDirectories(),
                        scheduled: scheduledPaths(home: home))
    }

    /// Every absolute path that appears in a LaunchAgent's program, arguments or working directory.
    static func scheduledPaths(home: URL) -> [String] {
        var paths: [String] = []
        func collect(_ value: Any) {
            if let text = value as? String {
                for token in text.split(whereSeparator: { " =:,;'\"".contains($0) }) {
                    let path = expandTilde(String(token), home: home)
                    if path.hasPrefix("/") { paths.append(path) }
                }
            } else if let list = value as? [Any] {
                list.forEach(collect)
            } else if let dictionary = value as? [String: Any] {
                dictionary.values.forEach(collect)
            }
        }
        for file in Files.children(home.path + "/Library/LaunchAgents") where file.hasSuffix(".plist") {
            guard let data = FileManager.default.contents(atPath: file),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            for key in ["Program", "ProgramArguments", "WorkingDirectory", "EnvironmentVariables"] {
                if let value = plist[key] { collect(value) }
            }
        }
        return paths
    }

    /// Whether any running process was launched from one of these executables.
    func isRunning(_ tools: [String]) -> String? {
        for command in commands {
            let executable = command.split(separator: " ").first.map(String.init) ?? command
            let name = (executable as NSString).lastPathComponent
            if let tool = tools.first(where: { name == $0 }) { return tool }
        }
        return nil
    }
}

/// Keeps a scan from calling something safe while it is in use or the user has protected it.
/// Runs after every rule, so no rule can forget it.
enum Protection {
    /// Shared caches and the build tools that read them. Deleting one mid-build breaks the build.
    private static let toolFamilies: [(marker: String, tools: [String])] = [
        ("/.cargo/registry", ["cargo", "rustc", "rustdoc", "cargo-clippy", "clippy-driver"]),
        ("/.rustup", ["cargo", "rustc", "rustup"]),
        ("/Library/Caches/org.swift.swiftpm", ["swift-build", "swift-package", "swift-test", "xcodebuild", "swift-frontend"]),
        ("/Library/Caches/com.apple.dt.Xcode", ["xcodebuild", "Xcode", "swift-frontend"]),
        ("/Library/Developer/Xcode/DerivedData", ["xcodebuild", "Xcode", "swift-frontend", "XCBBuildService", "SWBBuildService"]),
        ("/Library/Developer/CoreSimulator/Caches", ["xcodebuild", "launchd_sim"]),
        ("/.bun/install/cache", ["bun"]),
        ("/.npm/_cacache", ["npm", "npx"]),
        ("/Library/Caches/Yarn", ["yarn"]),
        ("/Library/pnpm/store", ["pnpm"]),
        ("/.gradle/caches", ["gradle", "gradlew", "java"]),
        ("/Library/Caches/CocoaPods", ["pod"]),
        ("/.cocoapods/repos", ["pod"]),
        ("/Library/Caches/pip", ["pip", "pip3", "uv"]),
        ("/Library/Caches/Homebrew", ["brew"]),
        ("/Library/Caches/ms-playwright", ["playwright"]),
    ]

    /// Every directory a running process stands in or names, plus all of their parents, so
    /// "is anything using this folder or something inside it" is one set lookup per finding.
    struct InUseIndex {
        var working: Set<String> = []
        var named: Set<String> = []
        var scheduled: Set<String> = []
        var activity: Activity

        init(_ activity: Activity) {
            self.activity = activity
            for cwd in activity.workingDirectories { Self.addAncestors(of: cwd, to: &working) }
            for path in activity.scheduled { Self.addAncestors(of: path, to: &scheduled) }
            for command in activity.commands {
                // Absolute paths appear as their own argument or after `=` (as in -Ldependency=/path).
                for token in command.split(whereSeparator: { $0 == " " || $0 == "=" || $0 == ":" || $0 == "," }) where token.hasPrefix("/") {
                    Self.addAncestors(of: String(token), to: &named)
                }
            }
        }

        private static func addAncestors(of path: String, to set: inout Set<String>) {
            var cursor = Substring(path)
            while cursor.count > 1, set.insert(String(cursor)).inserted {
                guard let slash = cursor.lastIndex(of: "/"), slash > cursor.startIndex else { break }
                cursor = cursor[..<slash]
            }
        }
    }

    static func apply(_ findings: [Finding], _ o: Options, activity: Activity) -> [Finding] {
        let index = InUseIndex(activity)
        let leases = o.pressroom ?? PressroomLeases.load(from: PressroomLeases.folder(home: o.home), now: o.now)
        let claims = Claims.live(LeaseStore(home: o.home), now: o.now)
        return findings.map { finding in
            var finding = finding
            if let claim = Claims.covering(finding.path, claims: claims) {
                finding.tier = .info
                finding.action = .none
                finding.reason = "claimed by \(claim.owner) until \(ISO8601DateFormatter().string(from: claim.expiresAt)); its owner removes it with `devdisk finish`"
                return finding
            }
            if let lease = leases.covering(finding.path) {
                finding.tier = .info
                finding.action = .none
                finding.reason = "leased by \(lease.holder) through pressroom (\(lease.kind)); a job is using it"
                return finding
            }
            if finding.tier == .safe, let reason = leases.refusal(finding.path) {
                finding.tier = .review
                finding.reason = reason
            }
            if !o.excludes.isEmpty, let pattern = exclusion(for: finding.path, o) {
                finding.tier = .info
                finding.action = .none
                finding.reason = "protected by the exclusion list (\(pattern))"
                return finding
            }
            if finding.tier == .safe, let reason = inUse(finding, index) ?? scheduledUse(finding, index, o) {
                finding.tier = .review
                finding.reason = reason
            }
            return finding
        }
    }

    /// Why a finding counts as in use, or nil.
    static func inUse(_ finding: Finding, _ index: InUseIndex) -> String? {
        let path = finding.path
        if index.working.contains(path) { return "a running process is working inside it" }
        // A build started from the project owns the project's build output.
        if finding.category == .artifacts {
            let project = (path as NSString).deletingLastPathComponent
            if index.working.contains(project) { return "a running process is working in this project" }
        }
        // Compilers and build tools name their output and cache folders in their arguments.
        if index.named.contains(path) { return "a running process refers to it on its command line" }
        for family in toolFamilies where path.contains(family.marker) {
            if let tool = index.activity.isRunning(family.tools) {
                return "\(tool) is running and may be reading it"
            }
        }
        return nil
    }

    /// Why a finding belongs to a job that runs on a timer, or nil. Such a job is usually not
    /// running during the scan, and it reads its dependencies without touching them.
    static func scheduledUse(_ finding: Finding, _ index: InUseIndex, _ o: Options) -> String? {
        if index.scheduled.contains(finding.path) { return "a LaunchAgent runs something inside it" }
        guard finding.category == .artifacts else { return nil }
        // Any folder between the project root and the build output that a job runs from.
        var cursor = Substring(finding.path)
        while let slash = cursor.lastIndex(of: "/"), slash > cursor.startIndex {
            cursor = cursor[..<slash]
            let folder = String(cursor)
            guard o.roots.contains(where: { $0.path != folder && Files.contains($0.path, folder) }) else { break }
            if index.scheduled.contains(folder) { return "a LaunchAgent runs from this project" }
        }
        return nil
    }

    /// The exclusion pattern that protects `path`, if any. A finding is protected when it
    /// matches a pattern, sits inside an excluded folder, or contains one.
    /// A line starting with `!` makes an exception: a path matching it, or inside it, is not
    /// protected by the other lines (`~/projects/app` with `!~/projects/app/target`).
    static func exclusion(for path: String, _ o: Options) -> String? {
        let exceptions = o.excludes.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        for exception in exceptions where fnmatch(exception, path, 0) == 0 || Files.contains(exception, path) {
            return nil
        }
        for pattern in o.excludes where !pattern.hasPrefix("!") {
            if fnmatch(pattern, path, 0) == 0 { return pattern }
            // Literal part of the pattern, up to its first wildcard.
            let literal = String(pattern.prefix { !"*?[".contains($0) })
            let isLiteral = literal.count == pattern.count
            if isLiteral, Files.contains(pattern, path) { return pattern }
            if Files.contains(path, isLiteral ? pattern : (literal as NSString).deletingLastPathComponent),
               literal.count > path.count { return pattern }
            // A wildcard pattern also protects everything under what it matches.
            var cursor = Substring(path)
            while let slash = cursor.lastIndex(of: "/"), slash > cursor.startIndex {
                cursor = cursor[..<slash]
                if fnmatch(pattern, String(cursor), 0) == 0 { return pattern }
            }
        }
        return nil
    }

    /// Reads one path or glob per line; `#` starts a comment and `~` means the home folder.
    static func loadExcludes(home: URL) -> [String] {
        let url = home.appendingPathComponent(".config/devdisk/exclude")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasPrefix("!") ? "!" + expandTilde(String($0.dropFirst()), home: home) : expandTilde($0, home: home) }
    }
}
