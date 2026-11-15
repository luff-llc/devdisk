import Foundation

/// A claim by one owner (an agent session, a task) on a resource devdisk manages.
/// The owner string is opaque to devdisk; a coordinator can use it
/// to reach whoever holds a resource instead of guessing whether it is still in use.
public struct Lease: Codable, Equatable, Sendable {
    public var owner: String
    /// `simulator` today; paths and worktrees can use the same store later.
    public var kind: String
    /// The simulator UDID.
    public var id: String
    public var createdAt: Date
    public var expiresAt: Date

    public init(owner: String, kind: String, id: String, createdAt: Date, expiresAt: Date) {
        self.owner = owner
        self.kind = kind
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// Leases live in one JSON file, guarded by `flock` so parallel agents cannot double-book.
public struct LeaseStore: Sendable {
    public var url: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let dir = ProcessInfo.processInfo.environment["DEVDISK_STATE_DIR"], !dir.isEmpty {
            url = URL(fileURLWithPath: dir).appendingPathComponent("leases.json")
        } else {
            url = home.appendingPathComponent(".local/state/devdisk/leases.json")
        }
    }

    public init(url: URL) { self.url = url }

    public func read() -> [Lease] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Lease].self, from: data)) ?? []
    }

    /// Runs `body` with exclusive access to the leases and saves what it leaves behind.
    @discardableResult
    public func mutate<T>(_ body: (inout [Lease]) -> T) -> T {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }
        var leases = read()
        let before = leases
        let result = body(&leases)
        if leases != before {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(leases).write(to: url, options: .atomic)
        }
        return result
    }
}

/// Parses `90s`, `30m`, `2h`, `1d` or plain seconds.
public func parseDuration(_ text: String) -> TimeInterval? {
    let units: [Character: Double] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
    if let last = text.last, let unit = units[last] {
        return Double(text.dropLast()).flatMap { $0 >= 0 ? $0 * unit : nil }
    }
    return Double(text).flatMap { $0 >= 0 ? $0 : nil }
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s >= 172_800 { return "\(s / 86400)d" }
    if s >= 3600 { return "\(s / 3600)h\(String(format: "%02d", s % 3600 / 60))m" }
    return "\(s / 60)m"
}
