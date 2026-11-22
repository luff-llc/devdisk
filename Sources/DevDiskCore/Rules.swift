import Foundation

/// Each rule proposes findings without sizes; the scanner measures them afterwards.
enum Rules {
    // MARK: Temporary directories

    static func tmp(_ o: Options) -> [Finding] {
        let uid = getuid()
        let active = Files.activeDirectories().filter { cwd in o.tmpDirs.contains { Files.contains($0.path, cwd) } }
        var findings: [Finding] = []
        for dir in o.tmpDirs {
            for path in Files.children(dir.path) {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == uid,
                      let type = attrs[.type] as? FileAttributeType,
                      type == .typeDirectory || type == .typeRegular else { continue }
                let name = (path as NSString).lastPathComponent
                if name.hasPrefix("com.apple.") || name == "TemporaryItems" { continue }
                if type == .typeDirectory, let parts = splitTmp(path, name: name, o) {
                    findings += parts
                    continue
                }
                // An entry modified recently is "review" whatever its children say, so only old
                // entries pay for the look inside.
                let own = (attrs[.modificationDate] as? Date).map { max(0, Int(o.now.timeIntervalSince($0) / 86400)) }
                let age = (own ?? 0) < o.tmpDays || type == .typeRegular ? own : Files.ageDays(path, now: o.now)
                let inUse = active.contains { Files.contains(path, $0) }
                var finding = Finding(category: .tmp, path: path, ageDays: age, tier: .safe,
                                      reason: "temporary files untouched for \(age ?? 0) days", action: .delete)
                // A linked git worktree must leave through git, so the repository's list stays true.
                // Without --force, git refuses if the worktree has uncommitted changes.
                if type == .typeDirectory, let repo = linkedWorktreeRepository(path) {
                    finding.action = .command(["git", "-C", repo, "worktree", "remove", path])
                    finding.reason = "git worktree of \(repo), untouched for \(age ?? 0) days"
                }
                if inUse {
                    finding.tier = .review
                    finding.reason = "a running process is working inside it"
                } else if (age ?? 0) < o.tmpDays {
                    finding.tier = .review
                    finding.reason = "modified within the last \(o.tmpDays) days"
                }
                findings.append(finding)
            }
        }
        return findings
    }

    /// For a linked worktree, the main repository it belongs to.
    static func linkedWorktreeRepository(_ path: String) -> String? {
        // `.git` is a file reading "gitdir: <repo>/.git/worktrees/<name>".
        guard let text = try? String(contentsOfFile: path + "/.git", encoding: .utf8), text.hasPrefix("gitdir: "),
              let range = text.range(of: "/.git/worktrees/") else { return nil }
        return String(text[text.index(text.startIndex, offsetBy: 8)..<range.lowerBound])
    }

    // MARK: Build artifacts inside project roots

    private static let alwaysArtifacts: Set<String> = [
        "node_modules", ".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache", "DerivedData",
    ]
    private static let markerArtifacts: [String: [String]] = [
        "target": ["Cargo.toml"],
        ".build": ["Package.swift"],
        "Pods": ["Podfile"],
    ]
    private static let ignoredOutputNames: Set<String> = ["build", "dist", "out"]

    static func artifacts(_ o: Options) -> [Finding] {
        // Each top-level project is walked on its own thread.
        var starts: [(String, Int)] = []
        var findings: [Finding] = []
        for root in o.roots {
            for entry in listing(root.path) where entry.isDirectory {
                let found = classify(entry.path, in: root.path, o)
                if !found.isEmpty {
                    findings += found
                } else if entry.name != ".git" {
                    starts.append((entry.path, 1))
                }
            }
        }
        return findings + parallelMap(starts) { start -> [Finding] in
            var found: [Finding] = []
            walk(start.0, depth: start.1, o, &found)
            return found
        }.flatMap { $0 }
    }

    private struct Entry {
        var path: String
        var name: String
        var isDirectory: Bool
    }

    /// Real directories (not symlinks) come back flagged; the attributes arrive with the listing.
    private static func listing(_ dir: String) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: keys, options: [])) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let real = values?.isDirectory == true && values?.isSymbolicLink != true
            return Entry(path: dir + "/" + url.lastPathComponent, name: url.lastPathComponent, isDirectory: real)
        }
    }

    /// Findings if `path` is a build artifact, none if it is an ordinary directory to descend into.
    private static func classify(_ path: String, in dir: String, _ o: Options) -> [Finding] {
        let name = (path as NSString).lastPathComponent
        if ignoredOutputNames.contains(name) {
            guard gitIgnores(path, in: dir) else { return [] }
            return splitOutput(path, o) ?? [Finding(
                category: .artifacts, path: path, ageDays: Files.ageDays(path, now: o.now), tier: .review,
                reason: "git-ignored output folder; may hold release builds or evidence worth keeping",
                action: .delete)]
        }
        return classifyOne(path, in: dir, o).map { [$0] } ?? []
    }

    private static func classifyOne(_ path: String, in dir: String, _ o: Options) -> Finding? {
        let name = (path as NSString).lastPathComponent
        var regenerable = alwaysArtifacts.contains(name)
        if let markers = markerArtifacts[name] {
            regenerable = markers.contains { FileManager.default.fileExists(atPath: dir + "/" + $0) }
        }
        // Anchor writes Solana program keypairs into target/deploy; those cannot be rebuilt.
        if regenerable, name == "target",
           Files.children(path + "/deploy").contains(where: { $0.hasSuffix("-keypair.json") }) {
            return Finding(
                category: .artifacts, path: path, ageDays: Files.ageDays(path, now: o.now), tier: .review,
                reason: "build output that also holds Solana program keypairs in target/deploy; back them up first",
                action: .delete)
        }
        if regenerable {
            let age = Files.ageDays(path, now: o.now)
            let fresh = (age ?? 0) < o.artifactDays
            return Finding(
                category: .artifacts, path: path, ageDays: age, tier: fresh ? .review : .safe,
                reason: fresh ? "regenerable \(name), but used within \(o.artifactDays) days"
                              : "regenerable \(name), untouched for \(age ?? 0) days",
                action: .delete)
        }
        return nil
    }

    private static func walk(_ dir: String, depth: Int, _ o: Options, _ findings: inout [Finding]) {
        guard depth <= o.maxDepth else { return }
        for entry in listing(dir) where entry.isDirectory && entry.name != ".git" {
            let found = classify(entry.path, in: dir, o)
            if !found.isEmpty {
                findings += found
            } else {
                walk(entry.path, depth: depth + 1, o, &findings)
            }
        }
    }

    private static func gitIgnores(_ path: String, in dir: String) -> Bool {
        Shell.run("git", ["-C", dir, "check-ignore", "-q", path], timeout: 10).status == 0
    }

    // MARK: Git worktrees

    static func worktrees(_ o: Options) -> [Finding] {
        var repos: [String] = []
        for root in o.roots {
            for path in [root.path] + Files.children(root.path) where isDirectory(path + "/.git") {
                repos.append(path)
            }
        }
        // OpenClaw keeps worktrees in one folder, away from the repositories they belong to.
        for path in Files.children(o.home.path + "/.openclaw/worktrees") {
            if let repo = linkedWorktreeRepository(path), !repos.contains(repo) { repos.append(repo) }
        }
        return parallelMap(repos) { worktrees(ofRepo: $0, o) }.flatMap { $0 }
    }

    private static func worktrees(ofRepo repo: String, _ o: Options) -> [Finding] {
        let listing = Shell.run("git", ["-C", repo, "worktree", "list", "--porcelain"], timeout: 20).output
        var entries: [(path: String, head: String)] = []
        for block in listing.components(separatedBy: "\n\n") {
            var path = "", head = ""
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
            }
            if !path.isEmpty { entries.append((path, head)) }
        }
        guard let main = entries.first, entries.count > 1 else { return [] }
        return parallelMap(Array(entries.dropFirst())) { entry in
            worktree(entry.path, head: entry.head, repo: repo, mainHead: main.head, o)
        }.compactMap { $0 }
    }

    private static func worktree(_ path: String, head: String, repo: String, mainHead: String, _ o: Options) -> Finding? {
        guard isDirectory(path) else { return nil }
        let age = Files.ageDays(path, now: o.now)
        var problems: [String] = []
        if (age ?? 0) < o.artifactDays { problems.append("activity within \(o.artifactDays) days") }
        let merged = Shell.run("git", ["-C", repo, "merge-base", "--is-ancestor", head, mainHead], timeout: 20).status == 0
        if !merged {
            let unpushed = Shell.run("git", ["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"], timeout: 20)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            if unpushed != "0" { problems.append("commits that are neither merged nor pushed") }
        }
        // `git status` reads the whole tree and is by far the slowest check, so it runs only
        // when the worktree would otherwise be safe. Some worktrees hang it; those stay undecided.
        if problems.isEmpty {
            let status = Shell.run("git", ["--no-optional-locks", "-C", path, "status", "--porcelain"], timeout: 8)
            if status.status != 0 {
                problems.append("a status check that failed or timed out")
            } else if !status.output.isEmpty {
                problems.append("uncommitted changes")
            }
        }
        return Finding(
            category: .worktrees, path: path, ageDays: age, tier: problems.isEmpty ? .safe : .review,
            reason: problems.isEmpty ? "clean worktree whose commits are merged or pushed"
                                     : "worktree has " + problems.joined(separator: ", "),
            action: .command(["git", "-C", repo, "worktree", "remove", path]))
    }

    // MARK: Xcode

    static func xcode(_ o: Options) -> [Finding] {
        let dev = o.home.path + "/Library/Developer"
        var findings: [Finding] = []
        for path in Files.children(dev + "/Xcode/DerivedData") where isDirectory(path) {
            let age = Files.ageDays(path, now: o.now)
            let fresh = (age ?? 0) < o.artifactDays
            findings.append(Finding(category: .xcode, path: path, ageDays: age, tier: fresh ? .review : .safe,
                                    reason: fresh ? "DerivedData built within \(o.artifactDays) days"
                                                  : "DerivedData, rebuilt on next build", action: .delete))
        }
        for platform in Files.children(dev + "/Xcode") where platform.hasSuffix("DeviceSupport") {
            // Folder names look like "iPhone18,1 27.0.1 (24A446)"; keep the newest per device model.
            let groups = Dictionary(grouping: Files.children(platform).filter(isDirectory)) {
                String(($0 as NSString).lastPathComponent.split(separator: " ").first ?? "")
            }
            for (_, paths) in groups {
                let sorted = paths.sorted { (Files.modified($0) ?? .distantPast) > (Files.modified($1) ?? .distantPast) }
                for (index, path) in sorted.enumerated() {
                    let age = Files.ageDays(path, now: o.now)
                    // The newest set is kept, unless it is so old that the device has surely moved on.
                    let stale = index == 0 && (age ?? 0) >= 180
                    findings.append(Finding(
                        category: .xcode, path: path, ageDays: age,
                        tier: index == 0 ? (stale ? .review : .info) : .safe,
                        reason: index == 0 ? (stale ? "debug symbols for this device, but \(age ?? 0) days old; it has likely updated since, and Xcode re-fetches them when it is connected"
                                                    : "debug symbols for the device's current OS")
                                           : "debug symbols for a superseded OS; Xcode re-fetches them from the device if needed",
                        action: index == 0 && !stale ? .none : .delete))
                }
            }
        }
        for path in Files.children(dev + "/Xcode/Archives") where isDirectory(path) {
            findings.append(Finding(category: .xcode, path: path, ageDays: Files.ageDays(path, now: o.now), tier: .review,
                                    reason: "app archives; contain dSYMs needed to symbolicate shipped builds", action: .delete))
        }
        for (path, reason) in [
            (dev + "/CoreSimulator/Caches", "simulator dyld caches, rebuilt on boot"),
            (o.home.path + "/Library/Caches/com.apple.dt.Xcode", "Xcode cache"),
        ] where isDirectory(path) {
            let age = Files.ageDays(path, now: o.now, depth: 2)
            let idle = (age ?? 0) >= o.artifactDays
            findings.append(Finding(category: .xcode, path: path, ageDays: age, tier: idle ? .safe : .review,
                                    reason: idle ? reason : reason + ", but used within \(o.artifactDays) days", action: .delete))
        }
        return findings
    }

    // MARK: Simulators

    static func simulators(_ o: Options) -> [Finding] {
        var findings: [Finding] = []
        var usedBy: [String: [String]] = [:]
        let iso = ISO8601DateFormatter()
        let limits = SimLimits()
        let temp = try? NSRegularExpression(pattern: limits.tempPattern)
        let leased = Set(LeaseStore(home: o.home).read().filter { $0.expiresAt > o.now }.map(\.id))
        func age(_ value: Any?) -> Int? {
            (value as? String).flatMap(iso.date).map { max(0, Int(o.now.timeIntervalSince($0) / 86400)) }
        }
        if let data = Shell.run("xcrun", ["simctl", "list", "devices", "-j"]).output.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let runtimes = root["devices"] as? [String: [[String: Any]]] {
            for (runtime, devices) in runtimes {
                let runtimeName = runtime.split(separator: ".").last.map(String.init) ?? runtime
                for device in devices {
                    guard let udid = device["udid"] as? String, let dataPath = device["dataPath"] as? String else { continue }
                    let name = device["name"] as? String ?? udid
                    usedBy[runtime, default: []].append(name)
                    let used = age(device["lastUsedAt"])
                    var finding = Finding(
                        category: .simulators, path: (dataPath as NSString).deletingLastPathComponent,
                        bytes: (device["dataPathSize"] as? NSNumber)?.int64Value ?? 0, ageDays: used,
                        tier: .info, reason: "simulator \(name) (\(runtimeName)), recently used",
                        action: .command(["xcrun", "simctl", "delete", udid]))
                    if device["isAvailable"] as? Bool == false {
                        finding.tier = .safe
                        finding.reason = "simulator \(name) (\(runtimeName)) has no installed runtime and cannot boot"
                    } else if device["state"] as? String == "Booted" {
                        finding.reason = "simulator \(name) (\(runtimeName)) is booted"
                        finding.action = .none
                    } else if !leased.contains(udid), device["state"] as? String == "Shutdown",
                              temp?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil,
                              (used ?? Int.max) >= Int(limits.tempAge / 86400) {
                        finding.tier = .safe
                        finding.reason = "temporary simulator \(name) (\(runtimeName)) unused for \(simulatorAge(used)); `devdisk sim reap --apply` removes these too"
                    } else if (used ?? Int.max) >= o.simulatorDays {
                        finding.tier = .review
                        finding.reason = "simulator \(name) (\(runtimeName)) unused for \(used.map { "\($0) days" } ?? "its whole life"); deleting loses its installed apps and data"
                    } else {
                        finding.action = .none
                    }
                    findings.append(finding)
                }
            }
        }
        if let data = Shell.run("xcrun", ["simctl", "runtime", "list", "-j"]).output.data(using: .utf8),
           let runtimes = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (identifier, runtime) in runtimes {
                let name = (runtime["runtimeIdentifier"] as? String)?.split(separator: ".").last.map(String.init) ?? identifier
                let used = age(runtime["lastUsedAt"])
                let devices = usedBy[runtime["runtimeIdentifier"] as? String ?? ""] ?? []
                let deletable = runtime["deletable"] as? Bool == true
                // No lastUsedAt means simctl has no record, not that the runtime is unused.
                let stale = deletable && ((used ?? 0) >= o.simulatorDays || devices.isEmpty)
                let users = devices.isEmpty ? "no simulator uses it"
                    : "used by \(devices.count) simulator\(devices.count == 1 ? "" : "s"): "
                      + devices.sorted().prefix(4).joined(separator: ", ") + (devices.count > 4 ? ", …" : "")
                findings.append(Finding(
                    category: .simulators, path: runtime["path"] as? String ?? identifier,
                    bytes: (runtime["sizeBytes"] as? NSNumber)?.int64Value ?? 0, ageDays: used,
                    tier: stale ? .review : .info,
                    reason: stale ? "simulator runtime \(name), \(users); unused for \(simulatorAge(used)); re-download is several GB"
                                  : "simulator runtime \(name), \(users)",
                    action: stale ? .command(["xcrun", "simctl", "runtime", "delete", identifier]) : .none))
            }
        }
        return findings
    }

    private static func simulatorAge(_ days: Int?) -> String { days.map { "\($0) days" } ?? "its whole life" }

    // MARK: Caches, browsers, agents, models, containers

    static func caches(_ o: Options) -> [Finding] {
        let home = o.home.path
        var findings: [Finding] = []
        let known: [(String, String)] = [
            (".npm/_cacache", "npm download cache"), (".bun/install/cache", "bun download cache"),
            (".gradle/caches", "Gradle dependency and build cache"), (".cargo/registry", "Cargo crate downloads"),
            (".cocoapods/repos", "CocoaPods spec repos"), ("Library/Caches/Homebrew", "Homebrew downloads"),
            ("Library/Caches/CocoaPods", "CocoaPods download cache"), ("Library/Caches/pip", "pip download cache"),
            ("Library/Caches/Yarn", "Yarn download cache"), ("Library/Caches/ms-playwright", "Playwright browsers"),
            ("Library/Caches/org.swift.swiftpm", "SwiftPM download cache"), ("Library/pnpm/store", "pnpm store"),
        ]
        for (relative, label) in known where isDirectory(home + "/" + relative) {
            let path = home + "/" + relative
            // Builds read these without touching them, and offline builds cannot re-download,
            // so a cache is safe only after a long idle stretch. Protection also checks for running tools.
            let age = Files.ageDays(path, now: o.now, depth: 2)
            let idle = (age ?? 0) >= o.cacheDays || relative == "Library/Caches/Homebrew"
            findings.append(Finding(
                category: .caches, path: path, ageDays: age, tier: idle ? .safe : .review,
                reason: idle ? label + ", untouched for \(age ?? 0) days; re-downloaded on demand"
                             : label + ", added to within \(o.cacheDays) days; offline builds need it",
                action: .delete))
        }
        for path in Files.children(home + "/.cache") where isDirectory(path) && !path.hasSuffix("/huggingface") {
            findings.append(Finding(category: .caches, path: path, ageDays: Files.ageDays(path, now: o.now), tier: .review,
                                    reason: "tool cache under ~/.cache; usually regenerable", action: .delete))
        }
        return findings
    }

    static func browsers(_ o: Options) -> [Finding] {
        // Chrome leaves a full copy of itself behind on every update: <user temp>/../X/com.google.Chrome.code_sign_clone
        var findings: [Finding] = []
        let chromeRunning = Shell.run("/usr/bin/pgrep", ["-x", "Google Chrome"]).status == 0
        for tmp in o.tmpDirs {
            let clones = tmp.deletingLastPathComponent().path + "/X/com.google.Chrome.code_sign_clone"
            let sorted = Files.children(clones).sorted { (Files.modified($0) ?? .distantPast) > (Files.modified($1) ?? .distantPast) }
            for (index, path) in sorted.enumerated() {
                let live = chromeRunning && index == 0
                findings.append(Finding(
                    category: .browsers, path: path, ageDays: Files.ageDays(path, now: o.now), tier: live ? .info : .safe,
                    reason: live ? "code-sign clone used by the running Chrome" : "leftover Chrome code-sign clone from an earlier launch",
                    action: live ? .none : .delete))
            }
        }
        return findings
    }

    private static func fixed(_ o: Options, _ category: Category, _ items: [(String, Tier, String)]) -> [Finding] {
        items.compactMap { relative, tier, reason in
            let path = o.home.path + "/" + relative
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Finding(category: category, path: path, ageDays: Files.ageDays(path, now: o.now), tier: tier,
                           reason: reason, action: tier == .info ? .none : .delete)
        }
    }

    static func agents(_ o: Options) -> [Finding] {
        openclaw(o) + fixed(o, .agents, [
            (".codex/sessions", .info, "Codex session transcripts"),
            (".codex/worktrees", .review, "Codex worktrees; check for unmerged work before removing"),
            (".codex/thread_history_1.sqlite", .info, "Codex thread history"),
            (".claude/projects", .info, "Claude Code session transcripts"),
            (".claude/spares", .review, "Claude Code spare checkouts"),
            ("Library/Application Support/Claude", .info, "Claude desktop app data, including session workspaces"),
            (".gemini", .info, "Gemini CLI data"),
            (".cursor", .info, "Cursor agent data"),
        ])
    }

    static func models(_ o: Options) -> [Finding] {
        fixed(o, .models, [
            (".lmstudio/models", .info, "LM Studio models; remove unused ones in LM Studio"),
            (".omlx/models", .info, "oMLX models"),
            (".omlx/cache", .review, "oMLX cache"),
            ("ComfyUI-Shared", .review, "ComfyUI model weights; a re-download is tens of GB"),
            (".ollama/models", .info, "Ollama models; remove with `ollama rm`"),
            (".cache/huggingface", .info, "Hugging Face model cache; prune with `hf cache delete`"),
        ])
    }

    static func containers(_ o: Options) -> [Finding] {
        fixed(o, .containers, [
            ("Library/Containers/com.docker.docker", .info, "Docker Desktop disk image; shrink with `docker system prune -a --volumes`"),
            (".orbstack", .info, "OrbStack data"),
            (".colima", .info, "Colima VM disks"),
            (".lima", .info, "Lima VM disks"),
            (".android/avd", .info, "Android emulator images"),
            ("Library/Android/sdk", .info, "Android SDK"),
        ])
    }
}
