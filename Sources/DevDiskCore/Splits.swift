import Foundation

/// Large folders that mix regenerable output with records worth keeping are reported part by
/// part, so a decision on one part does not have to cover the rest.
extension Rules {
    /// App archives in a release folder become safe after this many days; the receipts beside them stay.
    static let releaseArchiveDays = 30
    /// Agent session scratchpads become safe once the session has been idle this long.
    static let scratchpadDays = 7
    private static let evidenceFolders: Set<String> = ["reviews", "results", "runs"]

    // MARK: Output folders with releases and reviews

    /// The parts of a git-ignored output folder, or nil when it holds nothing worth splitting.
    static func splitOutput(_ path: String, _ o: Options) -> [Finding]? {
        let names = Set(Files.children(path).map { ($0 as NSString).lastPathComponent })
        let archives = find(in: path, depth: 4) { $0.hasSuffix(".xcarchive") }
        let derived = find(in: path, depth: 3) { $0 == "DerivedData" }
        guard names.contains("releases") || !names.isDisjoint(with: evidenceFolders) || !archives.isEmpty || !derived.isEmpty
        else { return nil }

        var findings = [Finding(
            category: .artifacts, path: path, ageDays: Files.ageDays(path, now: o.now), tier: .info,
            reason: "output folder, listed part by part; release receipts and logs are never offered", action: .none)]
        let covered = Set(archives + derived)
        for child in Files.children(path) where isDirectory(child) && !Files.isSymlink(child) {
            let name = (child as NSString).lastPathComponent
            let age = Files.ageDays(child, now: o.now)
            if covered.contains(child) { continue }
            if name == "releases" || archives.contains(where: { Files.contains(child, $0) }) && !evidenceFolders.contains(name) {
                findings.append(Finding(category: .artifacts, path: child, ageDays: age, tier: .info,
                                        reason: "release records; only the app archives inside are offered", action: .none))
            } else if evidenceFolders.contains(name) {
                findings.append(Finding(category: .artifacts, path: child, ageDays: age, tier: .info,
                                        reason: "\(name) folder, listed one entry at a time", action: .none))
                for entry in Files.children(child) where isDirectory(entry) && !Files.isSymlink(entry) && !covered.contains(entry) {
                    let entryAge = Files.ageDays(entry, now: o.now)
                    findings.append(Finding(
                        category: .artifacts, path: entry, ageDays: entryAge, tier: .review,
                        reason: "one \(name.dropLast()) folder, \(entryAge ?? 0) days old: test results, copies and evidence from that run",
                        action: .delete))
                }
            } else {
                findings.append(Finding(category: .artifacts, path: child, ageDays: age, tier: .review,
                                        reason: "part of a git-ignored output folder", action: .delete))
            }
        }
        // The newest archive of each app is the shipping build: its dSYMs symbolicate today's crash reports.
        let newest = Dictionary(grouping: archives) { ($0 as NSString).lastPathComponent }
            .compactMapValues { $0.max { (Files.modified($0) ?? .distantPast) < (Files.modified($1) ?? .distantPast) } }
        let newestPaths = Set(newest.values)
        for archive in archives {
            if let receipt = uploadReceipt(for: archive) {
                findings.append(Finding(
                    category: .artifacts, path: archive, ageDays: Files.ageDays(archive, now: o.now),
                    tier: receipt.processed ? .safe : .review,
                    reason: receipt.processed
                        ? "uploaded and processed by App Store Connect (\(receipt.name)); the receipt and IPA hash keep the evidence"
                        : "uploaded (\(receipt.name)), but App Store Connect processing is not verified yet",
                    action: .delete))
                continue
            }
            let age = Files.ageDays(archive, now: o.now)
            let latest = newestPaths.contains(archive)
            let old = !latest && (age ?? 0) >= releaseArchiveDays
            findings.append(Finding(
                category: .artifacts, path: archive, ageDays: age, tier: old ? .safe : .review,
                reason: (latest ? "newest archive of \((archive as NSString).lastPathComponent), likely the shipping build"
                         : old ? "superseded app archive, \(age ?? 0) days old" : "app archive from the last \(releaseArchiveDays) days")
                    + "; the receipts beside it stay",
                action: .delete))
        }
        for folder in derived {
            let age = Files.ageDays(folder, now: o.now)
            let fresh = (age ?? 0) < o.artifactDays
            findings.append(Finding(
                category: .artifacts, path: folder, ageDays: age, tier: fresh ? .review : .safe,
                reason: fresh ? "DerivedData used within \(o.artifactDays) days" : "DerivedData, rebuilt on the next build",
                action: .delete))
        }
        return findings
    }

    /// The upload receipt beside an archive (`upload.json` in its folder or the one above),
    /// when it names this archive and says it was uploaded. Processing counts as verified when
    /// the receipt says `processing_verified: true` or a sibling `processing.json` says `VALID`.
    static func uploadReceipt(for archive: String) -> (name: String, processed: Bool)? {
        let folder = (archive as NSString).deletingLastPathComponent
        for dir in [folder, (folder as NSString).deletingLastPathComponent] {
            let file = dir + "/upload.json"
            guard let data = FileManager.default.contents(atPath: file),
                  let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  receipt["status"] as? String == "uploaded",
                  let named = receipt["archive"] as? String,
                  named == archive || named.hasSuffix("/") && named.dropLast() == archive else { continue }
            let relative = file.hasPrefix(folder) ? "upload.json" : "../upload.json"
            let processing = FileManager.default.contents(atPath: dir + "/processing.json")
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let valid = (processing?["status"] as? String)?.uppercased() == "VALID"
            return (relative, receipt["processing_verified"] as? Bool == true || valid)
        }
        return nil
    }

    /// Directories under `root`, at most `depth` levels down, whose name matches. A match is not
    /// searched further, and `.git` is never entered.
    static func find(in root: String, depth: Int, _ match: (String) -> Bool) -> [String] {
        guard depth > 0 else { return [] }
        var found: [String] = []
        for child in Files.children(root) where isDirectory(child) && !Files.isSymlink(child) {
            let name = (child as NSString).lastPathComponent
            if name == ".git" { continue }
            if match(name) { found.append(child) } else { found += find(in: child, depth: depth - 1, match) }
        }
        return found
    }

    // MARK: Temporary folders with parts of their own

    /// A temp folder reported part by part, or nil to report it whole.
    static func splitTmp(_ path: String, name: String, _ o: Options) -> [Finding]? {
        if name.hasPrefix("claude-"), let parts = splitScratchpads(path, o) { return parts }
        if name.lowercased().contains("cache"), let parts = splitKeyedCache(path, o) { return parts }
        return nil
    }

    /// A cache keyed by hash or version: the newest two keys stay, older ones are superseded.
    static func splitKeyedCache(_ path: String, _ o: Options) -> [Finding]? {
        let keys = Files.children(path).filter { isDirectory($0) && !Files.isSymlink($0) }
            .map { ($0, Files.ageDays($0, now: o.now) ?? 0, Files.modified($0) ?? .distantPast) }
            .sorted { $0.2 > $1.2 }
        guard keys.count >= 3 else { return nil }
        var findings = [Finding(category: .tmp, path: path, ageDays: keys.first?.1, tier: .info,
                                reason: "cache with \(keys.count) keys, listed one key at a time", action: .none)]
        for (index, key) in keys.enumerated() {
            let newest = index < 2
            let stale = !newest && key.1 >= 1
            findings.append(Finding(
                category: .tmp, path: key.0, ageDays: key.1, tier: stale ? .safe : .review,
                reason: newest ? "one of the two newest cache keys" : stale ? "superseded cache key, untouched for \(key.1) days"
                                                                      : "superseded cache key, but used today",
                action: .delete))
        }
        return findings
    }

    /// `/tmp/claude-<uid>/<project>/<session id>/`: one entry per agent session.
    static func splitScratchpads(_ path: String, _ o: Options) -> [Finding]? {
        let projects = Files.children(path).filter { isDirectory($0) && !Files.isSymlink($0) }
        guard !projects.isEmpty else { return nil }
        let transcripts = transcriptAges(o)
        var findings = [Finding(category: .tmp, path: path, ageDays: Files.ageDays(path, now: o.now), tier: .info,
                                reason: "agent session scratchpads, listed one session at a time", action: .none)]
        for project in projects {
            for session in Files.children(project) where isDirectory(session) && !Files.isSymlink(session) {
                let id = (session as NSString).lastPathComponent
                // The session is as recent as its scratchpad or its transcript, whichever changed last.
                let ages = [Files.ageDays(session, now: o.now, depth: 3), transcripts[id]].compactMap { $0 }
                let age = ages.min() ?? 0
                let idle = age >= scratchpadDays
                findings.append(Finding(
                    category: .tmp, path: session, ageDays: age, tier: idle ? .safe : .review,
                    reason: idle ? "scratchpad of an agent session idle for \(age) days"
                                 : "scratchpad of an agent session active within \(scratchpadDays) days",
                    action: .delete))
            }
        }
        return findings
    }

    /// Days since each Claude Code session's transcript last changed, by session id.
    private static func transcriptAges(_ o: Options) -> [String: Int] {
        var ages: [String: Int] = [:]
        for project in Files.children(o.home.path + "/.claude/projects") {
            for file in Files.children(project) where file.hasSuffix(".jsonl") {
                guard let modified = Files.modified(file) else { continue }
                let id = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
                ages[id] = max(0, Int(o.now.timeIntervalSince(modified) / 86400))
            }
        }
        return ages
    }
}
