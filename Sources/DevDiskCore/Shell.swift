import Foundation

struct ShellResult {
    var status: Int32
    var output: String
}

enum Shell {
    /// Runs a tool and returns its stdout. Never throws: a missing tool yields status 127.
    @discardableResult
    /// A tool that outlives `timeout` seconds is terminated and reported with status -1.
    static func run(_ executable: String, _ arguments: [String], cwd: String? = nil, timeout: Double = 900) -> ShellResult {
        let started = Date()
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return ShellResult(status: 127, output: "") }
        let timedOut = Flag()
        let watchdog = DispatchWorkItem {
            timedOut.set()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if Date().timeIntervalSince(started) > 2 { trace("slow: \(executable) \(arguments.joined(separator: " "))", since: started) }
        return ShellResult(status: timedOut.isSet ? -1 : process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Runs `body` over `items` on up to `width` threads and keeps the results in order.
/// Unlike `DispatchQueue.concurrentPerform`, this stays parallel when called from inside
/// another parallel loop, which matters because most of the work is waiting on subprocesses.
func parallelMap<T, R>(_ items: [T], width: Int = 16, _ body: @escaping (T) -> R) -> [R] {
    guard items.count > 1 else { return items.map(body) }
    var results = [R?](repeating: nil, count: items.count)
    let lock = NSLock()
    let group = DispatchGroup()
    let slots = DispatchSemaphore(value: width)
    for (index, item) in items.enumerated() {
        slots.wait()
        group.enter()
        Thread.detachNewThread {
            let value = body(item)
            lock.lock()
            results[index] = value
            lock.unlock()
            slots.signal()
            group.leave()
        }
    }
    group.wait()
    return results.compactMap { $0 }
}

enum Sizer {
    /// Allocated size of each path. Hard links are counted once per top-level path, and a
    /// path nested inside another requested path is measured in the same pass as its parent.
    static func sizes(_ paths: [String]) -> [String: Int64] {
        let wanted = Set(paths)
        // Map each top-most path to the requested paths nested inside it.
        var groups: [String: Set<String>] = [:]
        for path in wanted {
            var top = path
            var cursor = Substring(path)
            while let slash = cursor.lastIndex(of: "/"), slash > cursor.startIndex {
                cursor = cursor[..<slash]
                if wanted.contains(String(cursor)) { top = String(cursor) }
            }
            groups[top, default: []].formUnion(top == path ? [] : [path])
        }
        // Largest groups tend to be the ones with nested findings; start them first.
        let roots = groups.keys.sorted { (groups[$0]?.count ?? 0) > (groups[$1]?.count ?? 0) }
        var result: [String: Int64] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: roots.count) { index in
            let root = roots[index]
            let measured = Walker.measure(root, watch: groups[root] ?? [])
            lock.lock()
            result[root] = measured.total
            result.merge(measured.watched) { a, _ in a }
            lock.unlock()
        }
        return result
    }
}

/// Remembers measured sizes between runs. An entry is reused while the path's own
/// modification time is unchanged and the measurement is younger than the time-to-live.
/// Changes deep inside a folder do not touch its modification time, so cached sizes are
/// estimates for ranking; tiers and ages are always computed fresh.
struct SizeCache {
    struct Entry: Codable {
        var bytes: Int64
        var modified: Double
        var measured: Double
    }

    var url: URL
    var ttl: TimeInterval
    var entries: [String: Entry] = [:]

    init(url: URL, ttl: TimeInterval) {
        self.url = url
        self.ttl = ttl
        if let data = try? Data(contentsOf: url) {
            entries = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
    }

    func lookup(_ path: String, now: Date) -> Int64? {
        guard let entry = entries[path], now.timeIntervalSince1970 - entry.measured < ttl,
              let modified = Files.modified(path)?.timeIntervalSince1970, modified == entry.modified else { return nil }
        return entry.bytes
    }

    /// Small entries are cheap to re-measure and would bloat the file.
    mutating func store(_ path: String, bytes: Int64, now: Date) {
        guard bytes >= 10 << 20, let modified = Files.modified(path)?.timeIntervalSince1970 else { return }
        entries[path] = Entry(bytes: bytes, modified: modified, measured: now.timeIntervalSince1970)
    }

    mutating func save(now: Date) {
        entries = entries.filter { now.timeIntervalSince1970 - $0.value.measured < ttl }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

enum Files {
    static func children(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).map { path + "/" + $0 }
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func isSymlink(_ path: String) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Days since the path or anything within `depth` levels below it changed.
    static func ageDays(_ path: String, now: Date, depth: Int = 1) -> Int? {
        newest(path, depth: depth).map { max(0, Int(now.timeIntervalSince($0) / 86400)) }
    }

    private static func newest(_ path: String, depth: Int) -> Date? {
        var newest = modified(path)
        guard depth > 0 else { return newest }
        for child in children(path).prefix(200) {
            let date = depth > 1 && isDirectory(child) ? Files.newest(child, depth: depth - 1) : modified(child)
            if let date, newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

    /// Working directories of this user's running processes.
    static func activeDirectories() -> [String] {
        Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn"]).output
            .split(separator: "\n")
            .filter { $0.hasPrefix("n/") }
            .map { String($0.dropFirst()) }
    }

    static func contains(_ parent: String, _ child: String) -> Bool {
        child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}
