import Foundation

public enum DevDiskCommandLine {
    public static let version = "0.8.0"

    static let usage = """
    devdisk \(version): explain and reclaim disk space used by local development

    USAGE
      devdisk status [--json]                 free space and pressure (ok | low | critical)
      devdisk status --need <size> [--floor <size>]   room for a job writing <size>? If not, which
                                              safe findings make room (exit 3 when there is not room)
      devdisk scan   [filters] [--json]       list what is using space, by category and tier
      devdisk clean  <selection> [--apply]    remove findings; a dry run unless --apply is given
      devdisk sim    <status|acquire|release|reap>   shared simulator pool; see `devdisk sim help`
      devdisk where [path] [--depth 4] [--min-size 2G] [--json]   size tree of a folder (default home),
                                              opening every part over --min-size, rule or no rule
      devdisk hidden [--json]                 space no scan can see: in use on the volume minus everything
                                              readable, the root-only folders behind the gap, Spotlight's state
      devdisk claim <path>... [--kind build|scratch|worktree]   mark what this session created
      devdisk release <path>...               give up claimed paths now (a finished worktree)
      devdisk finish [--scope NAME | --all] [--apply]   remove what this session claimed; see `devdisk claim help`
      devdisk sweep [--apply] [--install | --uninstall]   prune pressroom lanes of builds nothing needs;
                                              --install runs it hourly from a LaunchAgent
      devdisk guide                           conventions for coding agents (paste into AGENTS.md)

    FILTERS (scan and clean)
      --category <name>     repeatable: \(Category.allCases.map(\.rawValue).joined(separator: ", "))
      --root <dir>          repeatable project root (default: ~/projects, ~/code, ... or $DEVDISK_ROOTS)
      --min-size <size>     hide findings smaller than this (default 100M)
      --older-than <days>   age before build artifacts and worktrees count as safe (default 7d)
      --tmp-older-than <days>  age before temp entries count as safe (default 3d)
      --top <n>             scan only: show the n largest findings (default 40, 0 = all)
      --exclude <glob>      never offer this path or glob (also read from ~/.config/devdisk/exclude)
      --no-cache            measure every size now instead of reusing sizes from the last hour
      --cache-ttl <time>    how long a measured size is reused (default 1h)

    SELECTION (clean)
      --category <name>     every safe finding in the category
      --all-safe            every safe finding in every category
      --path <path>         one specific finding, exactly as scan printed it
      --allow-review        also remove review-tier findings that were selected
      --apply               actually remove; without it nothing is touched

    TIERS
      safe     regenerable, idle, and not in use by a running process; removed by clean
      review   needs a decision; removed only with --allow-review
      info     explains where space went; never removed by devdisk

    Removals are appended to ~/Library/Logs/devdisk.log.
    """

    public static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            print(usage)
            return 0
        }
        if command == "sim" { return SimCommand.run(Array(arguments.dropFirst())) }
        if ["claim", "claims", "unclaim", "finish", "release"].contains(command) {
            return ClaimCommand.run(command, Array(arguments.dropFirst()))
        }
        if command == "sweep" { return SweepCommand.run(Array(arguments.dropFirst())) }
        var args = Array(arguments.dropFirst())
        var options = Options()
        var request = CleanRequest()
        var json = false, top = 40, allSafe = false, useCache = true
        var need: Int64?, floor: Int64?, whereDepth = 4
        var categories: Set<Category> = []
        var roots: [URL] = []
        var excludes: [String] = []

        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("devdisk: \(message)\n".utf8))
            return 2
        }
        while !args.isEmpty {
            let flag = args.removeFirst()
            func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
            switch flag {
            case "--json": json = true
            case "--apply": request.apply = true
            case "--allow-review": request.allowReview = true
            case "--all-safe": allSafe = true
            case "--category":
                guard let raw = value(), let category = Category(rawValue: raw) else { return fail("unknown or missing category") }
                categories.insert(category)
            case "--root":
                guard let raw = value() else { return fail("--root needs a directory") }
                roots.append(URL(fileURLWithPath: expandTilde(raw, home: options.home)).standardizedFileURL)
            case "--path":
                guard let raw = value() else { return fail("--path needs a path") }
                request.paths.append(expandTilde(raw, home: options.home))
            case "--min-size":
                guard let bytes = value().flatMap(parseBytes) else { return fail("--min-size needs a size such as 500M") }
                options.minBytes = bytes
            case "--older-than":
                guard let days = value().flatMap(parseDays) else { return fail("--older-than needs days such as 7d") }
                options.artifactDays = days
            case "--tmp-older-than":
                guard let days = value().flatMap(parseDays) else { return fail("--tmp-older-than needs days such as 3d") }
                options.tmpDays = days
            case "--exclude":
                guard let raw = value() else { return fail("--exclude needs a path or glob") }
                excludes.append(expandTilde(raw, home: options.home))
            case "--depth":
                guard let n = value().flatMap(Int.init), n > 0 else { return fail("--depth needs a number") }
                whereDepth = n
            case "--need":
                guard let bytes = value().flatMap(parseBytes) else { return fail("--need needs a size such as 4G") }
                need = bytes
            case "--floor":
                guard let bytes = value().flatMap(parseBytes) else { return fail("--floor needs a size such as 20G") }
                floor = bytes
            case "--no-cache": useCache = false
            case "--cache-ttl":
                guard let ttl = value().flatMap(parseDuration) else { return fail("--cache-ttl needs a duration such as 1h") }
                options.sizeCacheTTL = ttl
            case "--top":
                guard let count = value().flatMap(Int.init) else { return fail("--top needs a number") }
                top = count
            default:
                if command == "where", !flag.hasPrefix("-") {
                    request.paths.append(expandTilde(flag, home: options.home))
                    continue
                }
                return fail("unknown option \(flag); run `devdisk help`")
            }
        }
        if !roots.isEmpty { options.roots = roots }
        options.excludes = Protection.loadExcludes(home: options.home) + excludes
        if useCache { options.sizeCache = LeaseStore(home: options.home).url.deletingLastPathComponent().appendingPathComponent("sizes.json") }

        switch command {
        case "help", "--help", "-h":
            print(usage)
        case "version", "--version":
            print(version)
        case "guide":
            print(Guide.text)
        case "status":
            let status = VolumeStatus.read()
            guard let need else {
                if json { emit(status) } else { print(status.summary) }
                return 0
            }
            let plan = RoomPlan.plan(need: need, floor: floor ?? RoomPlan.floor(home: options.home), volume: status) {
                Scanner.scan(options)
            }
            if json { emit(plan) } else { printRoom(plan, status) }
            return plan.enough ? 0 : 3
        case "where":
            let root = request.paths.first ?? args.first ?? options.home.path
            let minimum = options.minBytes == 100 << 20 ? Int64(2) << 30 : options.minBytes
            let node = Where.tree(root, depth: whereDepth, open: minimum)
            if json { emit(node) } else {
                var lines: [String] = []
                Where.print(node, minimum: minimum, out: &lines)
                Swift.print(lines.joined(separator: "\n"))
            }
        case "hidden":
            let report = Hidden.report()
            if json { emit(report) } else { printHidden(report) }
        case "scan":
            if !categories.isEmpty { options.categories = categories }
            let report = Scanner.scan(options)
            if json { emit(report) } else { printScan(report, top: top) }
        case "clean":
            if allSafe { categories = Set(Category.allCases) }
            guard !categories.isEmpty || !request.paths.isEmpty else {
                return fail("clean needs --category, --path or --all-safe")
            }
            request.categories = categories
            // Paths can belong to any category, so only narrow the scan when none were named.
            if request.paths.isEmpty { options.categories = categories }
            options.minBytes = min(options.minBytes, request.paths.isEmpty ? options.minBytes : 0)
            let before = VolumeStatus.read()
            let results = Cleaner.clean(Scanner.scan(options).findings, request, options: options)
            if json { emit(results) } else { printClean(results, apply: request.apply, before: before) }
            if results.contains(where: { $0.outcome == "failed" }) { return 1 }
        default:
            return fail("unknown command \(command); run `devdisk help`")
        }
        return 0
    }

    private static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func printScan(_ report: ScanReport, top: Int) {
        let volume = report.volume
        print(volume.summary)
        print("project roots: \(report.roots.isEmpty ? "(none found; pass --root)" : report.roots.joined(separator: ", "))\n")

        print("BY CATEGORY (nested findings counted once)")
        for category in Category.allCases {
            let items = report.findings.filter { $0.category == category }
            guard !items.isEmpty else { continue }
            let totals = Scanner.totals(items)
            let parts = ["safe", "review", "info"].compactMap { tier in
                totals[tier].map { "\(tier) \(formatBytes($0))" }
            }
            print("  \(pad(category.rawValue, 11)) \(pad("\(items.count) items", 10)) \(parts.joined(separator: ", "))")
        }
        let shown = top > 0 ? Array(report.findings.prefix(top)) : report.findings
        print("\nLARGEST FINDINGS (\(shown.count) of \(report.findings.count))")
        for finding in shown {
            let age = finding.ageDays.map { "\($0)d" } ?? "-"
            print("  \(pad(formatBytes(finding.bytes), 7)) \(pad(finding.tier.rawValue, 6)) \(pad(finding.category.rawValue, 10)) \(pad(age, 5)) \(finding.path)")
            print("  \(String(repeating: " ", count: 31))\(finding.reason)")
        }
        let total = { (tier: String) in formatBytes(report.totals[tier] ?? 0) }
        print("\nScanned in \(report.seconds)s\(report.sizesFromCache > 0 ? ", \(report.sizesFromCache) sizes reused from the last hour (--no-cache to re-measure)" : "").")
        print("TOTAL  safe \(total("safe"))   review \(total("review"))   info \(total("info"))")
        print("Reclaim the safe tier with `devdisk clean --all-safe` (dry run), then add --apply.")
    }

    static func printHidden(_ r: HiddenReport) {
        print("\(r.volume): \(formatBytes(r.inUseBytes)) in use, \(formatBytes(r.measuredBytes)) readable by you, gap \(formatBytes(max(0, r.gapBytes))) (\(r.seconds)s)")
        print("The gap is a lower bound: copies that share disk blocks are counted in full on the readable side.\n")
        print("Largest top-level folders (readable part):")
        for folder in r.folders.prefix(10) {
            let note = folder.unreadable.isEmpty ? "" : "  + \(folder.unreadable.count) folder(s) you cannot open"
            print("  \(formatBytes(folder.measuredBytes).padding(toLength: 8, withPad: " ", startingAt: 0)) \(folder.path)\(note)")
        }
        print("\nSpotlight:")
        for (volume, state) in r.spotlight.volumes.sorted(by: { $0.key < $1.key }) { print("  \(volume): \(state)") }
        print("  index server (mds_stores): \(formatBytes(r.spotlight.storesResidentBytes)) memory, \(String(format: "%.1f", r.spotlight.storesCPUPercent))% CPU")
        print("  per-app indexes in ~/Library/Metadata/CoreSpotlight: \(formatBytes(r.spotlight.appIndexesBytes))")
        print("\nLocal snapshots: \(r.snapshots.isEmpty ? "none" : r.snapshots.joined(separator: ", "))")
        if !r.suspects.isEmpty {
            print("\nRoot-only folders that commonly hide space:")
            for s in r.suspects { print("  \(s.path)\n      \(s.what)\n      fix: \(s.fix)") }
        }
        if !r.measureCommand.isEmpty {
            print("\nTo size the unreadable folders, run this yourself (it asks for your password):\n  \(r.measureCommand)")
        }
    }

    static func printRoom(_ plan: RoomPlan, _ status: VolumeStatus) {
        print(status.summary)
        let room = plan.freeBytes - plan.floorBytes
        if plan.enough {
            print("Room for \(formatBytes(plan.needBytes)): \(formatBytes(room)) above the \(formatBytes(plan.floorBytes)) floor.")
            return
        }
        print("Not enough room for \(formatBytes(plan.needBytes)): \(formatBytes(max(0, room))) above the \(formatBytes(plan.floorBytes)) floor, short by \(formatBytes(plan.shortfallBytes)).")
        guard !plan.findings.isEmpty else {
            print("No safe findings to clean; see `devdisk scan` for review items.")
            return
        }
        print(plan.coverable ? "These safe findings would make room (\(formatBytes(plan.findingsBytes)) measured; shared APFS blocks can free less):"
                             : "Every safe finding together is \(formatBytes(plan.findingsBytes)), not enough; review items are needed too:")
        for finding in plan.findings {
            print("  \(formatBytes(finding.bytes).padding(toLength: 7, withPad: " ", startingAt: 0)) \(finding.path)")
        }
        print("Remove them with:\n  " + plan.command.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))
    }

    private static func printClean(_ results: [CleanResult], apply: Bool, before: VolumeStatus) {
        if results.isEmpty {
            print("Nothing matched. Review-tier findings need --allow-review; info findings are never removed.")
            return
        }
        for result in results {
            print("  \(pad(result.outcome, 12)) \(pad(formatBytes(result.bytes), 7)) \(result.path)")
            if result.outcome == "failed" || result.outcome == "skipped" { print("               \(result.detail)") }
        }
        let bytes = results.filter { $0.outcome == (apply ? "removed" : "would-remove") }.reduce(Int64(0)) { $0 + $1.bytes }
        if apply {
            let after = VolumeStatus.read()
            print("\nRemoved \(formatBytes(bytes)). Free space: \(formatBytes(before.freeBytes)) -> \(formatBytes(after.freeBytes)). APFS can take minutes to report freed space; check again with `devdisk status`.")
            let deleted = Cleaner.trackedDeletions(results)
            if !deleted.isEmpty {
                print("\nWARNING: tracked files are gone in:")
                for line in deleted { print("  \(line)") }
            }
        } else {
            print("\nDry run: would remove \(formatBytes(bytes)) in \(results.count) items. Re-run with --apply to remove.")
        }
    }
}
