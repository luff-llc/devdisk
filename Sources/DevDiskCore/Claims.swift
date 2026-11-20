import Foundation

/// A session claims the scratch clones, build folders and worktrees it creates, and finishes
/// them when it is done. While a claim lives, no other session's cleanup may remove the path;
/// when the session ends, `finish` removes what it claimed. Claims share the lease store with
/// simulator leases, as kind `claim:<build|scratch|worktree>` with the path as the id.
public enum ClaimKind: String, Codable, CaseIterable, Sendable {
    /// Regenerable output: removed by `finish`.
    case build
    /// Temporary copies and working files: removed by `finish`.
    case scratch
    /// A git worktree: removed by `finish` only when clean and merged or pushed.
    case worktree
}

public struct FinishResult: Codable, Sendable {
    public var path: String
    public var kind: ClaimKind
    /// `would-remove`, `removed`, `kept`, `gone` or `failed`.
    public var outcome: String
    public var detail: String
}

public enum Claims {
    static let prefix = "claim:"
    public static let defaultTTL: TimeInterval = 7 * 86400

    /// The caller's owner id: `--owner`, else `$DEVDISK_OWNER`, else the agent session id.
    public static func defaultOwner(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let owner = env["DEVDISK_OWNER"], !owner.isEmpty { return owner }
        if let id = env["CLAUDE_CODE_SESSION_ID"], !id.isEmpty { return "claude:" + id }
        if let id = env["CODEX_SESSION_ID"] ?? env["CODEX_THREAD_ID"], !id.isEmpty { return "codex:" + id }
        return nil
    }

    public static func live(_ store: LeaseStore, now: Date = Date()) -> [Lease] {
        store.read().filter { $0.kind.hasPrefix(prefix) && $0.expiresAt > now }
    }

    public static func kind(of lease: Lease) -> ClaimKind? { ClaimKind(rawValue: String(lease.kind.dropFirst(prefix.count))) }

    /// Claims (or renews) `paths` for `owner`. Paths are resolved, so /tmp and /private/tmp match.
    @discardableResult
    public static func claim(_ paths: [String], kind: ClaimKind, owner: String, ttl: TimeInterval,
                             store: LeaseStore, now: Date = Date()) -> [Lease] {
        let resolved = paths.map(resolve)
        return store.mutate { leases in
            leases.removeAll { $0.kind.hasPrefix(prefix) && resolved.contains($0.id) && $0.owner == owner }
            let added = resolved.map { Lease(owner: owner, kind: prefix + kind.rawValue, id: $0, createdAt: now,
                                             expiresAt: now.addingTimeInterval(ttl)) }
            leases += added
            return added
        }
    }

    /// Drops claims without removing anything.
    public static func release(owner: String, paths: [String]?, store: LeaseStore) -> Int {
        let resolved = paths?.map(resolve)
        return store.mutate { leases in
            let before = leases.count
            leases.removeAll { $0.kind.hasPrefix(prefix) && $0.owner == owner && (resolved?.contains($0.id) ?? true) }
            return before - leases.count
        }
    }

    /// The live claim of another owner that covers `path`, if any.
    static func covering(_ path: String, claims: [Lease], except owner: String? = nil) -> Lease? {
        claims.first { $0.owner != owner && (Files.contains($0.id, path) || Files.contains(path, $0.id)) }
    }

    /// Removes what `owner` claimed: build and scratch paths outright, worktrees only when git says
    /// nothing would be lost. A path that is excluded, leased in pressroom, claimed by someone else,
    /// or still in use is kept. The owner's claims are dropped afterwards, including on paths kept.
    public static func finish(owner: String, apply: Bool, options o: Options, store: LeaseStore,
                              activity: Activity? = nil) -> [FinishResult] {
        let mine = live(store).filter { $0.owner == owner } + store.read().filter {
            $0.kind.hasPrefix(prefix) && $0.owner == owner && $0.expiresAt <= o.now
        }
        let others = live(store).filter { $0.owner != owner }
        let pressroom = o.pressroom ?? PressroomLeases.load(from: PressroomLeases.folder(home: o.home))
        let index = Protection.InUseIndex(activity ?? o.activity ?? Activity.current(home: o.home))
        var results: [FinishResult] = []
        // Innermost first, so a worktree's build folder goes before the worktree is checked.
        for claim in mine.sorted(by: { $0.id.count > $1.id.count }) {
            guard let kind = kind(of: claim) else { continue }
            let path = claim.id
            func result(_ outcome: String, _ detail: String) { results.append(FinishResult(path: path, kind: kind, outcome: outcome, detail: detail)) }
            guard FileManager.default.fileExists(atPath: path) else { result("gone", "already removed"); continue }
            let finding = Finding(category: .tmp, path: path, tier: .safe, reason: "", action: .delete)
            if let refused = Cleaner.refusal(finding, o) { result("kept", refused); continue }
            if let pattern = Protection.exclusion(for: path, o) { result("kept", "protected by the exclusion list (\(pattern))"); continue }
            if let why = pressroom.refusal(path) { result("kept", why); continue }
            if let other = covering(path, claims: others) { result("kept", "also claimed by \(other.owner)"); continue }
            if index.working.contains(path) { result("kept", "a running process is working inside it"); continue }

            if kind == .worktree {
                guard let repo = Rules.linkedWorktreeRepository(path) else { result("kept", "not a linked git worktree"); continue }
                let status = Shell.run("git", ["--no-optional-locks", "-C", path, "status", "--porcelain"], timeout: 20)
                let unpushed = Shell.run("git", ["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"], timeout: 20)
                    .output.trimmingCharacters(in: .whitespacesAndNewlines)
                let mainHead = Shell.run("git", ["-C", repo, "rev-parse", "HEAD"], timeout: 20).output.trimmingCharacters(in: .whitespacesAndNewlines)
                let merged = Shell.run("git", ["-C", path, "merge-base", "--is-ancestor", "HEAD", mainHead], timeout: 20).status == 0
                if status.status != 0 || !status.output.isEmpty { result("kept", "worktree has uncommitted changes"); continue }
                if unpushed != "0" && !merged { result("kept", "worktree has commits that are neither merged nor pushed"); continue }
                guard apply else { result("would-remove", "clean worktree of \(repo)"); continue }
                let run = Shell.run("git", ["-C", repo, "worktree", "remove", path], timeout: 120)
                run.status == 0 ? result("removed", "git worktree remove") : result("failed", "git worktree remove exited \(run.status)")
                continue
            }
            guard apply else { result("would-remove", "claimed \(kind.rawValue) folder"); continue }
            do {
                try FileManager.default.removeItem(atPath: path)
                result("removed", "claimed \(kind.rawValue) folder")
            } catch {
                result("failed", error.localizedDescription)
            }
        }
        if apply { _ = release(owner: owner, paths: nil, store: store) }
        return results
    }

    static func resolve(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }
}

/// `devdisk claim`, `devdisk claims`, `devdisk unclaim`, `devdisk finish`.
enum ClaimCommand {
    static let usage = """
    devdisk claim <path>... [--kind build|scratch|worktree] [--owner ID] [--ttl 7d]
        Mark paths this session created. Other sessions' cleanup leaves them alone until the claim
        ends; `finish` removes them. The owner defaults to $DEVDISK_OWNER or the agent session id.
    devdisk claims [--owner ID] [--json]       list live claims
    devdisk unclaim [<path>...] [--owner ID]   drop claims, removing nothing
    devdisk finish [--owner ID | --hook] [--apply] [--json]
        Remove what the owner claimed: build and scratch folders, and worktrees that are clean and
        merged or pushed. A dry run unless --apply. --hook reads the owner from a Claude Code hook's
        JSON on standard input (SessionEnd), so it can run when a session ends.
    """

    static func run(_ command: String, _ arguments: [String], store: LeaseStore = LeaseStore()) -> Int32 {
        var args = arguments
        var paths: [String] = []
        var owner = Claims.defaultOwner()
        var kind = ClaimKind.build, ttl = Claims.defaultTTL, apply = false, json = false, hook = false
        let home = FileManager.default.homeDirectoryForCurrentUser
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("devdisk: \(message)\n".utf8))
            return 2
        }
        while !args.isEmpty {
            let arg = args.removeFirst()
            func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
            switch arg {
            case "--owner": owner = value()
            case "--kind":
                guard let raw = value(), let parsed = ClaimKind(rawValue: raw) else { return fail("--kind is build, scratch or worktree") }
                kind = parsed
            case "--ttl":
                guard let parsed = value().flatMap(parseDuration) else { return fail("--ttl needs a duration such as 7d") }
                ttl = parsed
            case "--apply": apply = true
            case "--json": json = true
            case "--hook": hook = true
            case "help", "--help": print(usage); return 0
            default:
                if arg.hasPrefix("--") { return fail("unknown option \(arg)") }
                let expanded = expandTilde(arg, home: home)
                paths.append(expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded)
            }
        }
        if hook {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
                  let id = object["session_id"] as? String, !id.isEmpty else { return fail("--hook expects a hook's JSON with session_id on standard input") }
            owner = "claude:" + id
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        switch command {
        case "claim":
            guard let owner else { return fail("no owner: pass --owner or set DEVDISK_OWNER") }
            guard !paths.isEmpty else { return fail("claim needs at least one path") }
            for path in paths where !FileManager.default.fileExists(atPath: path) { return fail("\(path) does not exist") }
            let added = Claims.claim(paths, kind: kind, owner: owner, ttl: ttl, store: store)
            if json { print(String(decoding: (try? encoder.encode(added)) ?? Data(), as: UTF8.self)) }
            else { for lease in added { print("claimed \(lease.id) (\(kind.rawValue)) for \(owner) until \(ISO8601DateFormatter().string(from: lease.expiresAt))") } }
        case "claims":
            let shown = arguments.contains("--owner") ? Claims.live(store).filter { $0.owner == owner } : Claims.live(store)
            if json { print(String(decoding: (try? encoder.encode(shown)) ?? Data(), as: UTF8.self)) }
            else if shown.isEmpty { print("no live claims") }
            else { for c in shown { print("\(c.kind.dropFirst(Claims.prefix.count))\t\(c.owner)\t\(formatDuration(c.expiresAt.timeIntervalSinceNow)) left\t\(c.id)") } }
        case "unclaim":
            guard let owner else { return fail("no owner: pass --owner or set DEVDISK_OWNER") }
            print("dropped \(Claims.release(owner: owner, paths: paths.isEmpty ? nil : paths, store: store)) claim(s)")
        case "finish":
            guard let owner else { return fail("no owner: pass --owner, --hook, or set DEVDISK_OWNER") }
            var options = Options()
            options.excludes = Protection.loadExcludes(home: options.home)
            let results = Claims.finish(owner: owner, apply: apply, options: options, store: store)
            if json { print(String(decoding: (try? encoder.encode(results)) ?? Data(), as: UTF8.self)) }
            else if results.isEmpty { if !hook { print("nothing claimed by \(owner)") } }
            else { for r in results { print("\(r.outcome)\t\(r.kind.rawValue)\t\(r.path)\t\(r.detail)") } }
        default:
            print(usage)
        }
        return 0
    }
}
