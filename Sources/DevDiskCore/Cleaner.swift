import Foundation

public struct CleanResult: Codable, Sendable {
    public var path: String
    public var bytes: Int64
    public var tier: Tier
    /// `would-remove`, `removed`, `failed` or `skipped`.
    public var outcome: String
    public var detail: String
}

public struct CleanRequest: Sendable {
    public var categories: Set<Category> = []
    public var paths: [String] = []
    public var allowReview = false
    public var apply = false

    public init() {}
}

public enum Cleaner {
    /// Chooses findings to remove. Only scan findings are ever eligible; arbitrary paths are not.
    public static func select(_ findings: [Finding], _ request: CleanRequest) -> [Finding] {
        let paths = Set(request.paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let chosen = findings.filter { finding in
            guard finding.action != .none, finding.tier != .info else { return false }
            let named = paths.contains(URL(fileURLWithPath: finding.path).standardizedFileURL.path)
            guard named || request.categories.contains(finding.category) else { return false }
            return finding.tier == .safe || request.allowReview
        }
        // Drop findings nested inside another chosen one; removing the parent covers them.
        return chosen.filter { finding in
            !chosen.contains { $0.path != finding.path && Files.contains($0.path, finding.path) }
        }
    }

    public static func clean(_ findings: [Finding], _ request: CleanRequest, options: Options) -> [CleanResult] {
        let pressroomFolder = PressroomLeases.folder(home: options.home)
        return select(findings, request).map { finding in
            var result = CleanResult(path: finding.path, bytes: finding.bytes, tier: finding.tier,
                                     outcome: "would-remove", detail: finding.reason)
            guard request.apply else { return result }
            // A job may have started since the scan, so pressroom's leases are read again for every path.
            let leases = options.pressroom ?? PressroomLeases.load(from: pressroomFolder)
            if let refusal = refusal(finding, options) ?? leases.refusal(finding.path).map({ "skipped: " + $0 }) {
                result.outcome = "skipped"
                result.detail = refusal
                return result
            }
            switch finding.action {
            case .delete:
                // Inside pressroom's folders, removal goes through its delete lease so no job can
                // take a lease on the path mid-removal (contract rule 17).
                var deleteLease: String?
                if Files.contains(pressroomFolder.path, finding.path), let tool = Rules.pressroomTool() {
                    let begin = Shell.run(tool, ["delete-begin", "--holder", "devdisk", finding.path], timeout: 30)
                    guard begin.status == 0 else {
                        result.outcome = "skipped"
                        result.detail = "pressroom refused: " + begin.output.trimmingCharacters(in: .whitespacesAndNewlines)
                        log(result, home: options.home)
                        return result
                    }
                    deleteLease = begin.output.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                do {
                    try FileManager.default.removeItem(atPath: finding.path)
                    result.outcome = "removed"
                } catch {
                    result.outcome = "failed"
                    result.detail = error.localizedDescription
                }
                if let id = deleteLease, let tool = Rules.pressroomTool() {
                    Shell.run(tool, ["delete-end", id], timeout: 30)
                }
            case .command(let argv):
                let run = Shell.run(argv[0], Array(argv.dropFirst()))
                result.outcome = run.status == 0 ? "removed" : "failed"
                if run.status != 0 { result.detail = "`\(argv.joined(separator: " "))` exited \(run.status)" }
            case .none:
                result.outcome = "skipped"
            }
            log(result, home: options.home)
            return result
        }
    }

    /// Last line of defence: direct deletes must stay strictly inside home or a temp directory.
    /// After a clean: repositories where a tracked file now shows as deleted, with a few names.
    /// A rule that takes something git tracks is wrong, whatever it was.
    public static func trackedDeletions(_ results: [CleanResult]) -> [String] {
        var repos: Set<String> = []
        for result in results where result.outcome == "removed" {
            var dir = (result.path as NSString).deletingLastPathComponent
            while !dir.isEmpty, dir != "/", !FileManager.default.fileExists(atPath: dir) {
                dir = (dir as NSString).deletingLastPathComponent
            }
            let top = Shell.run("git", ["-C", dir, "rev-parse", "--show-toplevel"], timeout: 10)
            if top.status == 0 { repos.insert(top.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return repos.sorted().compactMap { repo in
            let status = Shell.run("git", ["--no-optional-locks", "-C", repo, "status", "--porcelain"], timeout: 30).output
            let deleted = status.split(separator: "\n").filter { $0.hasPrefix(" D") || $0.hasPrefix("D ") }
            guard !deleted.isEmpty else { return nil }
            let names = deleted.prefix(3).map { String($0.dropFirst(3)) }.joined(separator: ", ")
            return "\(repo): \(deleted.count) tracked file\(deleted.count == 1 ? "" : "s") now deleted (\(names)); restore with git restore"
        }
    }

    static func refusal(_ finding: Finding, _ o: Options) -> String? {
        guard finding.action == .delete else { return nil }
        // Not standardized: Foundation would strip /private and break the prefix comparison.
        let path = finding.path
        if path.contains("/../") || path.hasSuffix("/..") { return "refused: path contains .." }
        let bases = [o.home.path] + o.tmpDirs.flatMap { [$0.path, $0.deletingLastPathComponent().path + "/X"] }
        let inside = bases.contains { path != $0 && Files.contains($0, path) }
        if !inside { return "refused: outside the home and temp directories" }
        if path.split(separator: "/").count < 3 { return "refused: path is too close to the filesystem root" }
        if Files.isSymlink(path) { return "refused: path is a symbolic link" }
        return nil
    }

    private static func log(_ result: CleanResult, home: URL) {
        let url = home.appendingPathComponent("Library/Logs/devdisk.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(result.outcome) \(result.bytes) \(result.path)\n"
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
