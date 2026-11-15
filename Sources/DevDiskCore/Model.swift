import Foundation

/// How much judgment a finding needs before it is removed.
public enum Tier: String, Codable, Sendable {
    /// Regenerable and not recently used. `clean --apply` removes it.
    case safe
    /// Probably removable, but a person or agent must decide. Needs `--allow-review`.
    case review
    /// Reported so the space is explained. Never removed by this tool.
    case info
}

public enum Category: String, Codable, CaseIterable, Sendable {
    case tmp, artifacts, worktrees, xcode, simulators, caches, browsers, agents, models, containers
}

public enum Action: Codable, Equatable, Sendable {
    case delete
    case command([String])
    case none

    private enum CodingKeys: String, CodingKey { case kind, command }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .delete: try c.encode("delete", forKey: .kind)
        case .command(let argv):
            try c.encode("command", forKey: .kind)
            try c.encode(argv, forKey: .command)
        case .none: try c.encode("none", forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "delete": self = .delete
        case "command": self = .command(try c.decode([String].self, forKey: .command))
        default: self = .none
        }
    }
}

public struct Finding: Codable, Sendable {
    public var category: Category
    public var path: String
    public var bytes: Int64
    public var ageDays: Int?
    public var tier: Tier
    public var reason: String
    public var action: Action

    public init(category: Category, path: String, bytes: Int64 = 0, ageDays: Int? = nil,
                tier: Tier, reason: String, action: Action) {
        self.category = category
        self.path = path
        self.bytes = bytes
        self.ageDays = ageDays
        self.tier = tier
        self.reason = reason
        self.action = action
    }
}

public struct Options: Sendable {
    public var home: URL
    public var tmpDirs: [URL]
    public var roots: [URL]
    public var categories: Set<Category>
    public var minBytes: Int64 = 100 << 20
    public var tmpDays = 3
    public var artifactDays = 7
    public var simulatorDays = 30
    public var maxDepth = 7
    /// Where measured sizes are remembered between runs; nil measures everything every time.
    public var sizeCache: URL?
    public var sizeCacheTTL: TimeInterval = 3600
    public var now = Date()

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                tmpDirs: [URL]? = nil, roots: [URL]? = nil,
                categories: Set<Category> = Set(Category.allCases)) {
        self.home = home
        self.categories = categories
        self.tmpDirs = tmpDirs ?? Options.defaultTmpDirs()
        self.roots = roots ?? Options.defaultRoots(home: home)
    }

    static func defaultTmpDirs() -> [URL] {
        var dirs = [URL(fileURLWithPath: "/private/tmp")]
        // realpath keeps the /private prefix, matching what lsof and du report.
        if let real = realpath(NSTemporaryDirectory(), nil) {
            let user = String(cString: real)
            free(real)
            if user != "/private/tmp" { dirs.append(URL(fileURLWithPath: user)) }
        }
        return dirs
    }

    static func defaultRoots(home: URL) -> [URL] {
        if let env = ProcessInfo.processInfo.environment["DEVDISK_ROOTS"], !env.isEmpty {
            return env.split(separator: ":").map { URL(fileURLWithPath: expandTilde(String($0), home: home)) }
        }
        return ["projects", "code", "Developer", "src", "work", "repos", "dev", "git"]
            .map { home.appendingPathComponent($0) }
            .filter { isDirectory($0.path) }
    }
}

func expandTilde(_ path: String, home: URL) -> String {
    if path == "~" { return home.path }
    if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
    return path
}

func isDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

public func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "K", "M", "G", "T"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return unit < 2 ? "\(Int(value))\(units[unit])" : String(format: "%.1f%@", value, units[unit])
}

/// Parses sizes such as `500M`, `2G`, `1048576`.
public func parseBytes(_ text: String) -> Int64? {
    let upper = text.uppercased()
    let shifts: [Character: Int64] = ["K": 10, "M": 20, "G": 30, "T": 40]
    if let last = upper.last, let shift = shifts[last] {
        guard let value = Double(upper.dropLast()), value >= 0 else { return nil }
        return Int64(value * Double(Int64(1) << shift))
    }
    return Int64(upper).flatMap { $0 >= 0 ? $0 : nil }
}

/// Parses durations such as `7d` or `7` into days.
public func parseDays(_ text: String) -> Int? {
    let trimmed = text.hasSuffix("d") ? String(text.dropLast()) : text
    return Int(trimmed).flatMap { $0 >= 0 ? $0 : nil }
}
