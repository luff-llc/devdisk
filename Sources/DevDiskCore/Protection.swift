import Foundation

/// A snapshot of what is running, taken once per scan.
public struct Activity: Sendable {
    /// Full command lines of running processes.
    public var commands: [String]
    /// Working directories of this user's running processes.
    public var workingDirectories: [String]

    public init(commands: [String] = [], workingDirectories: [String] = []) {
        self.commands = commands
        self.workingDirectories = workingDirectories
    }

    static func current() -> Activity {
        let commands = Shell.run("/bin/ps", ["-axo", "command="], timeout: 30).output
            .split(separator: "\n").map(String.init)
        return Activity(commands: commands, workingDirectories: Files.activeDirectories())
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
        var activity: Activity

        init(_ activity: Activity) {
            self.activity = activity
            for cwd in activity.workingDirectories { Self.addAncestors(of: cwd, to: &working) }
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
        return findings.map { finding in
            var finding = finding
            if !o.excludes.isEmpty, let pattern = exclusion(for: finding.path, o) {
                finding.tier = .info
                finding.action = .none
                finding.reason = "protected by the exclusion list (\(pattern))"
                return finding
            }
            if finding.tier == .safe, let reason = inUse(finding, index) {
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

    /// The exclusion pattern that protects `path`, if any. A finding is protected when it
    /// matches a pattern, sits inside an excluded folder, or contains one.
    static func exclusion(for path: String, _ o: Options) -> String? {
        for pattern in o.excludes {
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
            .map { expandTilde($0, home: home) }
    }
}
