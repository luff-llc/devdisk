import Foundation

/// OpenClaw keeps its runtime, agent state, scratch space and the agents' project workspace
/// under `~/.openclaw`. Most of it is live state, so only scratch files and superseded
/// runtimes are ever safe; rollback snapshots and idle browser profiles need a decision.
extension Rules {
    static let openclawTmpDays = 14
    static let openclawBackupDays = 14
    static let openclawProfileDays = 30
    /// Scratch entries that hold live sockets, locks or compile caches of the running gateway.
    private static let openclawLiveTmp: Set<String> = ["node-compile-cache", "plugin-captures", "jiti"]

    /// Project folders inside OpenClaw that the artifact and worktree rules should also cover.
    static func openclawRoots(home: URL) -> [URL] {
        [".openclaw/workspace/projects", ".openclaw/worktrees"]
            .map { home.appendingPathComponent($0) }
            .filter { isDirectory($0.path) }
    }

    static func openclaw(_ o: Options) -> [Finding] {
        let root = o.home.path + "/.openclaw"
        guard isDirectory(root) else { return [] }
        func folders(_ path: String) -> [String] { Files.children(path).filter { isDirectory($0) && !Files.isSymlink($0) } }
        var findings: [Finding] = []

        // Rollback snapshots written by updates and repairs. Nothing retires them.
        for path in folders(root + "/backups") {
            let age = Files.ageDays(path, now: o.now)
            let old = (age ?? 0) >= openclawBackupDays
            findings.append(Finding(
                category: .agents, path: path, ageDays: age, tier: old ? .review : .info,
                reason: old ? "OpenClaw rollback snapshot, \(age ?? 0) days old; snapshots can share disk blocks with live files, so removing one may free less than its size"
                            : "OpenClaw rollback snapshot from the last \(openclawBackupDays) days",
                action: old ? .delete : .none))
        }

        // Database rollback copies and update captures belong to OpenClaw's own cleanup.
        for dir in [root + "/state"] + folders(root + "/agents").map({ $0 + "/agent" }) {
            for path in Files.children(dir) where path.hasSuffix(".bak")
                && (path.contains(".pre-startup-migration-") || path.contains(".doctor-cron-")) {
                findings.append(Finding(category: .agents, path: path, ageDays: Files.ageDays(path, now: o.now, depth: 0), tier: .info,
                                        reason: "OpenClaw database rollback copy; retire with `openclaw update cleanup`", action: .none))
            }
        }
        let captures = o.home.path + "/.openclaw.update-captures"
        if isDirectory(captures) {
            findings.append(Finding(
                category: .agents, path: captures, ageDays: Files.ageDays(captures, now: o.now), tier: .review,
                reason: "OpenClaw update captures; its own cleanup retires the ones no longer needed for rollback and keeps the rest",
                action: .command(["openclaw", "update", "cleanup", "--yes"])))
        }

        // Scratch space: browser test artifacts, sandboxes, one-off installs.
        for path in Files.children(root + "/tmp") where !Files.isSymlink(path) {
            let name = (path as NSString).lastPathComponent
            if openclawLiveTmp.contains(name) || name.hasPrefix("openclaw-") || name.hasPrefix("oc-br-") { continue }
            let age = Files.ageDays(path, now: o.now)
            let old = (age ?? 0) >= openclawTmpDays
            var finding = Finding(
                category: .agents, path: path, ageDays: age, tier: old ? .safe : .review,
                reason: old ? "OpenClaw scratch files untouched for \(age ?? 0) days"
                            : "OpenClaw scratch files modified within \(openclawTmpDays) days",
                action: .delete)
            if isDirectory(path), let repo = linkedWorktreeRepository(path) {
                finding.action = .command(["git", "-C", repo, "worktree", "remove", path])
            }
            findings.append(finding)
        }

        // Runtime generations: `current` runs, `previous` is the rollback target, the rest are spent.
        let runtime = root + "/runtime"
        func target(_ link: String) -> String? {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: runtime + "/" + link) else { return nil }
            let path = destination.hasPrefix("/") ? destination : runtime + "/" + destination
            return path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        // Without a readable `current` link the layout is not the one this rule knows.
        if let current = target("current") {
            let previous = target("previous")
            for path in folders(runtime) {
                let kept = path == current ? "the running OpenClaw runtime" : path == previous ? "OpenClaw's rollback runtime" : nil
                findings.append(Finding(
                    category: .agents, path: path, ageDays: Files.ageDays(path, now: o.now), tier: kept == nil ? .safe : .info,
                    reason: kept ?? "superseded OpenClaw runtime; neither current nor the rollback target",
                    action: kept == nil ? .delete : .none))
            }
        }

        // Browser profiles hold signed-in sessions, so they are never safe.
        for path in folders(root + "/browser") {
            let data = isDirectory(path + "/user-data") ? path + "/user-data" : path
            let age = Files.ageDays(data, now: o.now, depth: 2)
            let idle = (age ?? 0) >= openclawProfileDays
            findings.append(Finding(
                category: .agents, path: path, ageDays: age, tier: idle ? .review : .info,
                reason: idle ? "OpenClaw browser profile idle for \(age ?? 0) days; removing it signs that browser out everywhere"
                             : "OpenClaw browser profile in recent use",
                action: idle ? .delete : .none))
        }

        // Unique state, listed so the space is explained.
        for path in folders(root + "/agents") {
            findings.append(Finding(category: .agents, path: path, ageDays: Files.ageDays(path, now: o.now), tier: .info,
                                    reason: "OpenClaw agent state and session history", action: .none))
        }
        for path in folders(root + "/workspace/private") {
            findings.append(Finding(category: .agents, path: path, ageDays: Files.ageDays(path, now: o.now), tier: .info,
                                    reason: "agent workspace data; not regenerable, and retention belongs to the job that writes it", action: .none))
        }
        return findings
    }
}
