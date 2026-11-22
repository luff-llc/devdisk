import XCTest
@testable import DevDiskCore

final class DevDiskTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        let real = try XCTUnwrap(realpath(NSTemporaryDirectory(), nil))
        defer { free(real) }
        base = URL(fileURLWithPath: String(cString: real)).appendingPathComponent("devdisk-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    /// Creates a directory holding one file, with both dated `daysOld` days in the past.
    @discardableResult
    private func make(_ relative: String, daysOld: Int = 0, file: String = "data.bin") throws -> String {
        let dir = base.appendingPathComponent(relative)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let filePath = dir.appendingPathComponent(file).path
        fm.createFile(atPath: filePath, contents: Data(count: 8192))
        let date = Date().addingTimeInterval(-Double(daysOld) * 86400)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: filePath)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: dir.path)
        return dir.path
    }

    private func options(_ categories: Set<DevDiskCore.Category>) throws -> Options {
        var o = Options(home: base.appendingPathComponent("home"),
                        tmpDirs: [base.appendingPathComponent("tmp")],
                        roots: [base.appendingPathComponent("home/projects")],
                        categories: categories)
        o.minBytes = 0
        o.activity = Activity()
        try fm.createDirectory(at: o.home, withIntermediateDirectories: true)
        return o
    }

    func testParsing() {
        XCTAssertEqual(parseBytes("500M"), 500 << 20)
        XCTAssertEqual(parseBytes("2g"), 2 << 30)
        XCTAssertEqual(parseBytes("1024"), 1024)
        XCTAssertNil(parseBytes("lots"))
        XCTAssertEqual(parseDays("7d"), 7)
        XCTAssertNil(parseDays("-1"))
    }

    func testPressureThresholds() {
        let gb: Int64 = 1 << 30
        XCTAssertEqual(VolumeStatus.pressure(total: 1000 * gb, free: 15 * gb), "critical")
        XCTAssertEqual(VolumeStatus.pressure(total: 1000 * gb, free: 80 * gb), "low")
        XCTAssertEqual(VolumeStatus.pressure(total: 1000 * gb, free: 300 * gb), "ok")
    }

    func testArtifactsAreTieredByAgeAndMarker() throws {
        let o = try options([.artifacts])
        let old = try make("home/projects/app/node_modules", daysOld: 30)
        let fresh = try make("home/projects/web/node_modules", daysOld: 0)
        let cargo = try make("home/projects/crate/target", daysOld: 30)
        try make("home/projects/crate", file: "Cargo.toml")
        let notCargo = try make("home/projects/notes/target", daysOld: 30)

        let findings = Scanner.scan(o).findings
        let tier = { (path: String) in findings.first { $0.path == path }?.tier }
        XCTAssertEqual(tier(old), .safe)
        XCTAssertEqual(tier(fresh), .review)
        XCTAssertEqual(tier(cargo), .safe)
        XCTAssertNil(tier(notCargo), "a folder named target without Cargo.toml is not an artifact")
        XCTAssertTrue(findings.allSatisfy { $0.bytes > 0 })
    }

    func testTmpEntriesBecomeSafeOnlyWhenOld() throws {
        let o = try options([.tmp])
        let old = try make("tmp/review-clone", daysOld: 10)
        let fresh = try make("tmp/active-clone", daysOld: 0)
        let findings = Scanner.scan(o).findings
        XCTAssertEqual(findings.first { $0.path == old }?.tier, .safe)
        XCTAssertEqual(findings.first { $0.path == fresh }?.tier, .review)
    }

    func testDeviceSupportKeepsNewestPerDevice() throws {
        let o = try options([.xcode])
        let support = "home/Library/Developer/Xcode/iOS DeviceSupport/"
        let older = try make(support + "iPhone18,1 27.0 (24A437)", daysOld: 40)
        let newer = try make(support + "iPhone18,1 27.0.1 (24A446)", daysOld: 5)
        let findings = Scanner.scan(o).findings
        XCTAssertEqual(findings.first { $0.path == older }?.tier, .safe)
        XCTAssertEqual(findings.first { $0.path == newer }?.tier, .info)
    }

    func testCleanIsDryRunUntilApplied() throws {
        let o = try options([.artifacts])
        let old = try make("home/projects/app/node_modules", daysOld: 30)
        let fresh = try make("home/projects/web/node_modules", daysOld: 0)
        let findings = Scanner.scan(o).findings

        var request = CleanRequest()
        request.categories = [.artifacts]
        let dry = Cleaner.clean(findings, request, options: o)
        XCTAssertEqual(dry.map(\.path), [old], "review-tier findings are not selected without allowReview")
        XCTAssertEqual(dry.first?.outcome, "would-remove")
        XCTAssertTrue(fm.fileExists(atPath: old))

        request.apply = true
        XCTAssertEqual(Cleaner.clean(findings, request, options: o).first?.outcome, "removed")
        XCTAssertFalse(fm.fileExists(atPath: old))
        XCTAssertTrue(fm.fileExists(atPath: fresh))

        request.paths = [fresh]
        request.categories = []
        request.allowReview = true
        XCTAssertEqual(Cleaner.clean(findings, request, options: o).first?.outcome, "removed")
        XCTAssertFalse(fm.fileExists(atPath: fresh))
    }

    func testCleanIgnoresPathsThatAreNotFindings() throws {
        let o = try options([.artifacts])
        let precious = try make("home/projects/app/src")
        var request = CleanRequest()
        request.paths = [precious]
        request.allowReview = true
        request.apply = true
        XCTAssertTrue(Cleaner.clean(Scanner.scan(o).findings, request, options: o).isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: precious))
    }

    func testDeleteRefusedOutsideHomeAndTmp() throws {
        let o = try options([])
        let outside = Finding(category: .caches, path: "/usr/local/lib", tier: .safe, reason: "", action: .delete)
        XCTAssertNotNil(Cleaner.refusal(outside, o))
        let home = Finding(category: .caches, path: o.home.path, tier: .safe, reason: "", action: .delete)
        XCTAssertNotNil(Cleaner.refusal(home, o))
        let inside = Finding(category: .caches, path: o.home.path + "/.npm/_cacache", tier: .safe, reason: "", action: .delete)
        XCTAssertNil(Cleaner.refusal(inside, o))
    }

    func testTotalsCountNestedFindingsOnce() {
        let parent = Finding(category: .worktrees, path: "/r/wt", bytes: 100, tier: .review, reason: "", action: .delete)
        let child = Finding(category: .artifacts, path: "/r/wt/node_modules", bytes: 60, tier: .safe, reason: "", action: .delete)
        let other = Finding(category: .artifacts, path: "/r/wt2/node_modules", bytes: 5, tier: .safe, reason: "", action: .delete)
        XCTAssertEqual(Scanner.totals([parent, child, other]), ["review": 100, "safe": 5])
    }

    // MARK: Simulators

    private func device(_ name: String, _ udid: String, state: String = "Shutdown", type: String = "T.iPhone-18-Pro",
                        available: Bool = true, lastUsedHoursAgo: Double? = nil) -> SimDevice {
        SimDevice(udid: udid, name: name, state: state, runtime: "R.iOS-27-0", deviceType: type, isAvailable: available,
                  dataBytes: 1 << 30, lastUsedAt: lastUsedHoursAgo.map { Date().addingTimeInterval(-$0 * 3600) })
    }

    private func lease(_ owner: String, _ udid: String, hours: Double = 4) -> Lease {
        Lease(owner: owner, kind: "simulator", id: udid, createdAt: Date(), expiresAt: Date().addingTimeInterval(hours * 3600))
    }

    func testPickReusesPoolBeforeCreating() {
        var limits = SimLimits(memoryBytes: 64 << 30)
        limits.poolMax = 2
        let now = Date()
        let pick = { (devices: [SimDevice], leases: [Lease]) in
            SimPlanner.pick(devices: devices, leases: leases, owner: "me", deviceType: "T.iPhone-18-Pro",
                            runtime: "R.iOS-27-0", limits: limits, now: now)
        }
        let mine = device("My iPhone", "U0")
        let one = device("devdisk-iPhone-18-Pro-1", "U1")
        let two = device("devdisk-iPhone-18-Pro-2", "U2", state: "Booted")

        XCTAssertEqual(pick([mine], []), .create(name: "devdisk-iPhone-18-Pro-1"), "devices devdisk did not create are never handed out")
        XCTAssertEqual(pick([mine, one, two], []), .reuse(two), "a warm device is preferred")
        XCTAssertEqual(pick([one, two], [lease("other", "U2")]), .reuse(one))
        XCTAssertEqual(pick([one, two], [lease("me", "U1")]), .held(one), "acquire is idempotent per owner")
        if case .full(let holders) = pick([one, two], [lease("a", "U1"), lease("b", "U2")]) {
            XCTAssertEqual(holders.map(\.owner), ["a", "b"])
        } else {
            XCTFail("a fully leased pool at its cap must report its holders")
        }
        XCTAssertEqual(pick([one, two], [lease("a", "U1", hours: -1), lease("b", "U2")]), .reuse(one), "expired leases free the device")
    }

    func testBootRefusedOverLimits() {
        var limits = SimLimits(memoryBytes: 64 << 30)
        XCTAssertEqual(limits.maxBooted, 2)
        limits.minFreePercent = 20
        let booted = [device("a", "U1", state: "Booted"), device("b", "U2", state: "Booted")]
        XCTAssertNotNil(SimPlanner.bootRefusal(devices: booted, memoryLevel: 80, limits: limits))
        XCTAssertNotNil(SimPlanner.bootRefusal(devices: [booted[0]], memoryLevel: 10, limits: limits))
        XCTAssertNil(SimPlanner.bootRefusal(devices: [booted[0]], memoryLevel: 50, limits: limits))
    }

    func testReapPlan() {
        let limits = SimLimits(memoryBytes: 64 << 30)
        let devices = [
            device("iPhone 18 Pro", "IDLE", state: "Booted"),
            device("devdisk-iPhone-18-Pro-1", "LEASED", state: "Booted"),
            device("Fresh", "FRESH", state: "Booted"),
            device("App-Temp-abc", "OLDTEMP", lastUsedHoursAgo: 48),
            device("App-Temp-def", "NEWTEMP", lastUsedHoursAgo: 2),
            device("Template Phone", "NOTTEMP", lastUsedHoursAgo: 900),
            device("Orphan", "DEAD", available: false),
        ]
        let old = SimUsage(residentBytes: 5_000_000_000, processes: 300, bootedSeconds: 700_000)
        let fresh = SimUsage(residentBytes: 5_000_000_000, processes: 300, bootedSeconds: 600)
        let usage: [String: SimUsage] = ["IDLE": old, "LEASED": old, "FRESH": fresh]
        let plan = SimPlanner.reap(devices: devices, usage: usage, leases: [lease("me", "LEASED")], limits: limits, now: Date())
        let planned: [String] = plan.map { "\($0.udid):\($0.action)" }.sorted()
        XCTAssertEqual(planned, ["DEAD:delete", "IDLE:shutdown", "OLDTEMP:delete"])
    }

    func testProcessTreeAttribution() {
        let ps = """
            1     0   100 30-00:00:00 /sbin/launchd
          200     1  2048 08-05:36:06 launchd_sim /Users/x/Library/Developer/CoreSimulator/Devices/093C6346-A281-4C2E-8D6F-A6E10BDEB4CE/data/var/run/launchd_bootstrap.plist
          201   200  1024    01:00:00 /path/SpringBoard.app/SpringBoard
          202   201  1024       05:00 /path/My App.app/My App --flag
          300     1  4096    00:10:00 /Applications/Safari.app/Contents/MacOS/Safari
        """
        let usage = SimPlanner.usage(psOutput: ps)
        XCTAssertEqual(usage.count, 1)
        let sim = usage["093C6346-A281-4C2E-8D6F-A6E10BDEB4CE"]
        XCTAssertEqual(sim?.processes, 3)
        XCTAssertEqual(sim?.residentBytes, 4096 * 1024)
        XCTAssertEqual(sim?.bootedSeconds, 711_366)
    }

    func testLeaseStoreRoundTrip() throws {
        let store = LeaseStore(url: base.appendingPathComponent("state/leases.json"))
        XCTAssertTrue(store.read().isEmpty)
        store.mutate { $0.append(self.lease("me", "U1")) }
        XCTAssertEqual(store.read().map(\.owner), ["me"])
        store.mutate { $0.removeAll() }
        XCTAssertTrue(store.read().isEmpty)
        XCTAssertEqual(parseDuration("30m"), 1800)
        XCTAssertEqual(parseDuration("1d"), 86400)
        XCTAssertNil(parseDuration("soon"))
    }

    // MARK: Measuring

    private func du(_ path: String) -> Int64 {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", "-x", path]
        process.standardOutput = pipe
        try? process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (Int64(text.split(separator: "\t").first ?? "") ?? -1) * 1024
    }

    func testWalkerMatchesDuAndCountsHardLinksOnce() throws {
        let root = try make("tree/a/b/c")
        try make("tree/a/b/c/deep/deeper")
        try make("tree/a/sibling", file: "file with spaces and ünïcode.bin")
        let big = root + "/big.bin"
        fm.createFile(atPath: big, contents: Data(count: 3 << 20))
        try fm.linkItem(atPath: big, toPath: root + "/hardlink.bin")
        try fm.createSymbolicLink(atPath: root + "/link-out", withDestinationPath: "/usr")
        // An empty file and a directory with enough entries to need more than one name table row.
        fm.createFile(atPath: root + "/empty", contents: nil)
        for i in 0..<600 { fm.createFile(atPath: root + "/n\(i)", contents: Data(count: 100)) }

        let tree = base.appendingPathComponent("tree").path
        let watchPath = tree + "/a/b"
        let measured = Walker.measure(tree, watch: [watchPath])
        // du also counts the blocks of directories themselves; allow for that, nothing more.
        XCTAssertEqual(Double(measured.total), Double(du(tree)), accuracy: 64 * 1024)
        XCTAssertEqual(Double(measured.watched[watchPath] ?? -1), Double(du(watchPath)), accuracy: 64 * 1024)
        XCTAssertGreaterThan(measured.total, 3 << 20)
        XCTAssertLessThan(measured.total, 7 << 20, "the hard link must not be counted twice (that would be over 8 MB)")
        XCTAssertEqual(Walker.measure(tree + "/missing"), Walker.Measurement())
        XCTAssertGreaterThanOrEqual(Walker.measure(big).total, 3 << 20, "a plain file is measured directly")
    }

    func testSizerMeasuresNestedPathsInOnePass() throws {
        let outer = try make("nest/outer")
        let inner = try make("nest/outer/node_modules")
        fm.createFile(atPath: inner + "/blob", contents: Data(count: 2 << 20))
        let other = try make("nest/other")
        let sizes = Sizer.sizes([outer, inner, other])
        XCTAssertEqual(Set(sizes.keys), [outer, inner, other])
        XCTAssertGreaterThan(sizes[inner] ?? 0, 2 << 20)
        XCTAssertGreaterThanOrEqual(sizes[outer] ?? 0, sizes[inner] ?? 0)
    }

    func testSizeCacheReusesUntilPathChanges() throws {
        var o = try options([.artifacts])
        o.sizeCache = base.appendingPathComponent("state/sizes.json")
        let modules = try make("home/projects/app/node_modules", daysOld: 30)
        fm.createFile(atPath: modules + "/blob", contents: Data(count: 12 << 20))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86400)], ofItemAtPath: modules)

        XCTAssertEqual(Scanner.scan(o).sizesFromCache, 0)
        let second = Scanner.scan(o)
        XCTAssertEqual(second.sizesFromCache, 1)
        XCTAssertGreaterThan(second.findings.first?.bytes ?? 0, 12 << 20)

        fm.createFile(atPath: modules + "/new-entry", contents: Data(count: 1))
        XCTAssertEqual(Scanner.scan(o).sizesFromCache, 0, "a changed folder is measured again")
    }

    // MARK: Protection

    func testRunningBuildsKeepTheirCachesAndOutput() throws {
        var o = try options([.artifacts, .caches])
        let registry = try make("home/.cargo/registry", daysOld: 90)
        let target = try make("home/projects/crate/target", daysOld: 30)
        try make("home/projects/crate", file: "Cargo.toml")
        let modules = try make("home/projects/app/node_modules", daysOld: 30)
        let tier = { (o: Options, path: String) in Scanner.scan(o).findings.first { $0.path == path }?.tier }

        XCTAssertEqual(tier(o, registry), .safe)
        XCTAssertEqual(tier(o, target), .safe)

        o.activity = Activity(commands: ["/Users/x/.cargo/bin/cargo build --offline"])
        XCTAssertEqual(tier(o, registry), .review, "the registry is not safe while cargo runs anywhere")
        XCTAssertEqual(tier(o, modules), .safe, "an unrelated project is unaffected")

        o.activity = Activity(workingDirectories: [base.appendingPathComponent("home/projects/crate/src").path])
        XCTAssertEqual(tier(o, target), .review, "a process working in the project protects its build output")
        XCTAssertEqual(tier(o, registry), .safe)

        o.activity = Activity(commands: ["rustc --crate-name x -L dependency=\(target)/debug/deps"])
        XCTAssertEqual(tier(o, target), .review, "a compiler naming the folder protects it")
    }

    func testScheduledJobsKeepTheirProjectsBuildOutput() throws {
        var o = try options([.artifacts])
        let modules = try make("home/projects/pipeline/app/node_modules", daysOld: 60)
        let other = try make("home/projects/idle/node_modules", daysOld: 60)
        let agents = base.appendingPathComponent("home/Library/LaunchAgents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        let job: [String: Any] = ["Label": "x.pipeline", "ProgramArguments": ["/bin/zsh", "-lc", "cd ~/projects/pipeline/jobs && bun run pull.ts"]]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            .write(to: agents.appendingPathComponent("x.pipeline.plist"))
        o.activity = Activity(scheduled: Activity.scheduledPaths(home: o.home))
        let found = Scanner.scan(o).findings
        XCTAssertEqual(found.first { $0.path == modules }?.tier, .review, "a timer job elsewhere in the project protects it")
        XCTAssertEqual(found.first { $0.path == other }?.tier, .safe)
    }

    func testOpenClawTiers() throws {
        let o = try options([.agents, .artifacts])
        let claw = "home/.openclaw"
        let oldBackup = try make("\(claw)/backups/update-20261001", daysOld: 40)
        let newBackup = try make("\(claw)/backups/repair-20261112", daysOld: 2)
        let oldTmp = try make("\(claw)/tmp/playwright-artifacts-AbC123", daysOld: 20)
        let newTmp = try make("\(claw)/tmp/sandbox-xYz789", daysOld: 1)
        let liveTmp = try make("\(claw)/tmp/node-compile-cache", daysOld: 20)
        let current = try make("\(claw)/runtime/2026.11.1-release", daysOld: 10)
        let previous = try make("\(claw)/runtime/2026.10.10-release", daysOld: 12)
        let spent = try make("\(claw)/runtime/2026.10.8-release", daysOld: 30)
        try fm.createSymbolicLink(atPath: base.path + "/\(claw)/runtime/current", withDestinationPath: "2026.11.1-release")
        try fm.createSymbolicLink(atPath: base.path + "/\(claw)/runtime/previous", withDestinationPath: previous)
        let profile = try make("\(claw)/browser/imported/user-data", daysOld: 50)
        let state = try make("\(claw)/agents/main/agent", daysOld: 0, file: "openclaw-agent.sqlite.pre-startup-migration-1.bak")
        let keys = try make("home/projects/chain/target/deploy", daysOld: 60, file: "program-keypair.json")
        try make("home/projects/chain", file: "Cargo.toml")

        let found = Scanner.scan(o).findings
        let tier = { (path: String) in found.first { $0.path == path }?.tier }
        XCTAssertEqual(tier(oldBackup), .review)
        XCTAssertEqual(tier(newBackup), .info)
        XCTAssertEqual(tier(oldTmp), .safe)
        XCTAssertEqual(tier(newTmp), .review)
        XCTAssertNil(tier(liveTmp), "live scratch folders are never offered")
        XCTAssertEqual(tier(current), .info)
        XCTAssertEqual(tier(previous), .info)
        XCTAssertEqual(tier(spent), .safe)
        XCTAssertEqual(tier((profile as NSString).deletingLastPathComponent), .review)
        XCTAssertEqual(tier(state + "/openclaw-agent.sqlite.pre-startup-migration-1.bak"), .info)
        XCTAssertEqual(tier((keys as NSString).deletingLastPathComponent), .review, "a target folder with program keypairs is not regenerable")
    }

    // MARK: Split folders, pressroom, volume

    private func git(_ args: String..., in dir: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    func testReleaseOutputIsSplitAndReceiptsStay() throws {
        let o = try options([.artifacts])
        let app = base.appendingPathComponent("home/projects/app").path
        let oldArchive = try make("home/projects/app/build/releases/1.0-1/App.xcarchive", daysOld: 40)
        let newArchive = try make("home/projects/app/build/releases/1.1-2/App.xcarchive", daysOld: 35)
        let receipts = try make("home/projects/app/build/releases/1.0-1", file: "upload.json")
        let review = try make("home/projects/app/build/reviews/2026-10-01-search", daysOld: 40)
        try "build/\n".write(toFile: app + "/.gitignore", atomically: true, encoding: .utf8)
        git("init", "-q", in: app)

        let findings = Scanner.scan(o).findings
        let tier = { (path: String) in findings.first { $0.path == path }?.tier }
        XCTAssertEqual(tier(app + "/build"), .info)
        XCTAssertEqual(tier(app + "/build/releases"), .info)
        XCTAssertEqual(tier(oldArchive), .safe)
        XCTAssertEqual(tier(newArchive), .review, "the newest archive of an app is kept even when old")
        XCTAssertEqual(tier(review), .review)
        XCTAssertNil(tier(receipts), "a release folder holding receipts is never offered")
        var all = CleanRequest()
        all.categories = Set(DevDiskCore.Category.allCases)
        let chosen = Cleaner.select(findings, all).map(\.path)
        XCTAssertEqual(chosen, [oldArchive], "a safe clean takes the old archive and nothing beside it")
    }

    func testUploadReceiptDecidesArchive() throws {
        let o = try options([.artifacts])
        let app = base.appendingPathComponent("home/projects/app").path
        let processed = try make("home/projects/app/build/releases/2.0-5/ios/App.xcarchive", daysOld: 1)
        let pending = try make("home/projects/app/build/releases/2.0-6/ios/App.xcarchive", daysOld: 1)
        for (archive, verified) in [(processed, true), (pending, false)] {
            let receipt = #"{"status":"uploaded","processing_verified":\#(verified),"archive":"\#(archive)","ipa_sha256":"ab"}"#
            try receipt.write(toFile: (archive as NSString).deletingLastPathComponent + "/upload.json", atomically: true, encoding: .utf8)
        }
        try "build/\n".write(toFile: app + "/.gitignore", atomically: true, encoding: .utf8)
        git("init", "-q", in: app)
        let findings = Scanner.scan(o).findings
        XCTAssertEqual(findings.first { $0.path == processed }?.tier, .safe, "uploaded and processed: the receipt is the evidence")
        XCTAssertEqual(findings.first { $0.path == pending }?.tier, .review, "processing not verified yet")

        // A later verify step records processing beside the receipt instead of editing it.
        let verified = #"{"status":"VALID","asc_build_id":"1","observed_utc":"2026-11-20T20:00:00Z"}"#
        try verified.write(toFile: (pending as NSString).deletingLastPathComponent + "/processing.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(Scanner.scan(o).findings.first { $0.path == pending }?.tier, .safe, "processing.json with VALID counts")
    }

    func testRoomPlanNamesSafeFindings() {
        let gb: Int64 = 1 << 30
        let volume = VolumeStatus(totalBytes: 900 * gb, freeBytes: 22 * gb, freeIncludingPurgeableBytes: 30 * gb, pressure: "critical")
        let finding = { (path: String, size: Int64, tier: Tier) in
            Finding(category: .artifacts, path: path, bytes: size * gb, tier: tier, reason: "", action: .delete)
        }
        let report = ScanReport(volume: volume, roots: [], findings: [
            finding("/a", 1, .safe), finding("/b", 3, .safe), finding("/c", 9, .review), finding("/d", 2, .safe),
        ], totals: [:], belowMinimum: [:], sizesFromCache: 0, seconds: 0)
        XCTAssertTrue(RoomPlan.plan(need: 1 * gb, floor: 20 * gb, volume: volume) { report }.enough)
        let plan = RoomPlan.plan(need: 6 * gb, floor: 20 * gb, volume: volume) { report }
        XCTAssertFalse(plan.enough)
        XCTAssertEqual(plan.shortfallBytes, 4 * gb)
        XCTAssertEqual(plan.findings.map(\.path), ["/b", "/d"], "largest safe findings first, review items never")
        XCTAssertTrue(plan.coverable)
    }

    func testKeyedCacheKeepsNewestKeys() throws {
        let o = try options([.tmp])
        let cache = "tmp/app-build-cache"
        let newest = try make("\(cache)/aaa", daysOld: 0)
        try make("\(cache)/bbb", daysOld: 0)
        let older = try make("\(cache)/ccc", daysOld: 2)
        let oldest = try make("\(cache)/ddd", daysOld: 5)
        let findings = Scanner.scan(o).findings
        let tier = { (path: String) in findings.first { $0.path == path }?.tier }
        XCTAssertEqual(tier(base.appendingPathComponent(cache).path), .info)
        XCTAssertEqual(tier(newest), .review)
        XCTAssertEqual(tier(older), .safe)
        XCTAssertEqual(tier(oldest), .safe)
    }

    func testScratchpadsFollowSessionActivity() throws {
        let o = try options([.tmp])
        let idle = try make("tmp/claude-501/project/session-idle/scratchpad", daysOld: 10)
        let live = try make("tmp/claude-501/project/session-live/scratchpad", daysOld: 10)
        try make("home/.claude/projects/project", file: "session-live.jsonl")
        for session in [idle, live] {
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)],
                                 ofItemAtPath: (session as NSString).deletingLastPathComponent)
        }
        let findings = Scanner.scan(o).findings
        let tier = { (path: String) in findings.first { $0.path == (path as NSString).deletingLastPathComponent }?.tier }
        XCTAssertEqual(tier(idle), .safe)
        XCTAssertEqual(tier(live), .review, "a session whose transcript changed today keeps its scratchpad")
    }

    func testPressroomLeasesProtectPaths() throws {
        var o = try options([.artifacts])
        let leased = try make("home/projects/app/node_modules", daysOld: 30)
        let other = try make("home/projects/web/node_modules", daysOld: 30)
        let leases = base.appendingPathComponent("home/.pressroom/leases")
        try fm.createDirectory(at: leases, withIntermediateDirectories: true)
        let expires = Int(Date().timeIntervalSince1970) + 3600
        let lease = #"{"version":"pressroom.lease/1","id":"j1","holder":"agent:taupe","kind":"worktree","mode":"in-use","paths":["\#(base.appendingPathComponent("home/projects/app").path)"],"created":1,"expires":\#(expires)}"#
        try lease.write(to: leases.appendingPathComponent("j1.json"), atomically: true, encoding: .utf8)

        var findings = Scanner.scan(o).findings
        XCTAssertEqual(findings.first { $0.path == leased }?.tier, .info, "a path inside a leased worktree is left alone")
        XCTAssertEqual(findings.first { $0.path == other }?.tier, .safe)

        try "not json".write(to: leases.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        findings = Scanner.scan(o).findings
        XCTAssertEqual(findings.first { $0.path == other }?.tier, .review, "an unreadable lease could cover anything")

        // A lease taken after the scan still stops the removal.
        try fm.removeItem(at: leases.appendingPathComponent("broken.json"))
        findings = Scanner.scan(o).findings
        let late = lease.replacingOccurrences(of: "projects/app", with: "projects/web")
        try late.write(to: leases.appendingPathComponent("j2.json"), atomically: true, encoding: .utf8)
        o.pressroom = nil
        var request = CleanRequest()
        request.categories = [.artifacts]
        request.apply = true
        let results = Cleaner.clean(findings, request, options: o)
        XCTAssertEqual(results.first { $0.path == other }?.outcome, "skipped")
        XCTAssertTrue(fm.fileExists(atPath: other))
    }

    func testVolumeSummaryShowsBothFreeFigures() {
        let gb: Int64 = 1 << 30
        let v = VolumeStatus(totalBytes: 926 * gb, freeBytes: 20 * gb, freeIncludingPurgeableBytes: 35 * gb,
                             pressure: VolumeStatus.pressure(total: 926 * gb, free: 20 * gb))
        XCTAssertEqual(v.summary, "20.0G free (35.0G counting purgeable) of 926.0G, pressure: critical")
    }

    func testExclusionExceptions() throws {
        var o = try options([.artifacts])
        let project = base.appendingPathComponent("home/projects/crate").path
        let target = try make("home/projects/crate/target", daysOld: 30)
        try make("home/projects/crate", file: "Cargo.toml")
        o.excludes = [project]
        XCTAssertEqual(Scanner.scan(o).findings.first { $0.path == target }?.tier, .info)
        o.excludes = [project, "!" + target]
        XCTAssertEqual(Scanner.scan(o).findings.first { $0.path == target }?.tier, .safe, "an exception reopens target/")
    }

    func testClaimsProtectAndFinishRemoves() throws {
        var o = try options([.tmp])
        let store = LeaseStore(url: base.appendingPathComponent("home/.local/state/devdisk/leases.json"))
        let scratch = try make("tmp/session-a-clone", daysOld: 10)
        let build = try make("tmp/session-a-build", daysOld: 0)
        let theirs = try make("tmp/session-b-clone", daysOld: 10)
        o.pressroom = PressroomLeases()
        Claims.claim([scratch], kind: .scratch, owner: "a", ttl: 3600, store: store)
        Claims.claim([build], kind: .build, owner: "a", ttl: 3600, store: store)
        Claims.claim([theirs], kind: .scratch, owner: "b", ttl: 3600, store: store)

        let findings = Scanner.scan(o).findings
        XCTAssertEqual(findings.first { $0.path == scratch }?.tier, .info, "a live claim keeps other cleanups away, however old")

        let dry = Claims.finish(owner: "a", apply: false, options: o, store: store, activity: Activity())
        XCTAssertEqual(Set(dry.map(\.outcome)), ["would-remove"])
        XCTAssertTrue(fm.fileExists(atPath: build))

        let done = Claims.finish(owner: "a", apply: true, options: o, store: store, activity: Activity())
        XCTAssertEqual(done.filter { $0.outcome == "removed" }.count, 2, "fresh build output goes too: its owner is done with it")
        XCTAssertFalse(fm.fileExists(atPath: scratch))
        XCTAssertTrue(fm.fileExists(atPath: theirs), "another owner's claim is untouched")
        XCTAssertEqual(Claims.live(store).map(\.owner), ["b"], "the finished owner's claims are dropped")
    }

    func testFinishKeepsDirtyWorktree() throws {
        var o = try options([.tmp])
        o.pressroom = PressroomLeases()
        let store = LeaseStore(url: base.appendingPathComponent("home/.local/state/devdisk/leases.json"))
        let repo = base.appendingPathComponent("home/projects/repo").path
        try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", in: repo)
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init", in: repo)
        let wt = base.appendingPathComponent("tmp/wt").path
        git("worktree", "add", "-q", "-b", "feature", wt, in: repo)
        try "change".write(toFile: wt + "/new.txt", atomically: true, encoding: .utf8)
        Claims.claim([wt], kind: .worktree, owner: "a", ttl: 3600, store: store)
        let results = Claims.finish(owner: "a", apply: true, options: o, store: store, activity: Activity())
        XCTAssertEqual(results.first?.outcome, "kept")
        XCTAssertTrue(fm.fileExists(atPath: wt + "/new.txt"))

        try fm.removeItem(atPath: wt + "/new.txt")
        Claims.claim([wt], kind: .worktree, owner: "a", ttl: 3600, store: store)
        XCTAssertEqual(Claims.finish(owner: "a", apply: true, options: o, store: store, activity: Activity()).first?.outcome, "removed",
                       "a clean worktree whose commit is on main leaves through git")
        XCTAssertFalse(fm.fileExists(atPath: wt))
    }

    func testWhereOpensLargeFoldersAndHiddenCollapses() throws {
        try make("home/projects/big/a", file: "x.bin")
        try make("home/projects/big/b", file: "y.bin")
        try make("home/projects/small", file: "z.bin")
        let root = base.appendingPathComponent("home/projects").path
        let tree = Where.tree(root, depth: 3, open: 12 << 10)
        let big = tree.children.first { $0.path.hasSuffix("/big") }
        XCTAssertEqual(tree.children.first?.path, big?.path, "largest first")
        XCTAssertEqual(big?.children.count, 2, "a folder over the threshold is opened")
        XCTAssertEqual(tree.children.first { $0.path.hasSuffix("/small") }?.children.count, 0)
        XCTAssertEqual(tree.bytes, tree.children.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(Hidden.collapse(["/a/b/c", "/a/b", "/x", "/a/bc"]), ["/x", "/a/b", "/a/bc"])
    }

    func testStaleDeviceSupportNeedsReview() throws {
        let o = try options([.xcode])
        let old = try make("home/Library/Developer/Xcode/visionOS DeviceSupport/RealityDevice14,1 1.1.1 (21O224)", daysOld: 400)
        let current = try make("home/Library/Developer/Xcode/iOS DeviceSupport/iPhone19,2 27.2 (24B119)", daysOld: 10)
        let findings = Scanner.scan(o).findings
        XCTAssertEqual(findings.first { $0.path == old }?.tier, .review, "the only set for a device, but over 180 days old")
        XCTAssertEqual(findings.first { $0.path == current }?.tier, .info)
    }

    func testFreshCachesNeedReview() throws {
        let o = try options([.caches])
        let registry = try make("home/.cargo/registry/cache/index.crates.io", daysOld: 2)
        let parent = (registry as NSString).deletingLastPathComponent
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-90 * 86400)], ofItemAtPath: parent)
        let finding = Scanner.scan(o).findings.first { $0.path.hasSuffix(".cargo/registry") }
        XCTAssertEqual(finding?.tier, .review, "a crate downloaded two levels down counts as recent use")
    }

    func testExclusionListProtectsPathsAndGlobs() throws {
        var o = try options([.artifacts, .tmp])
        let kept = try make("home/projects/wt/h1-build/node_modules", daysOld: 30)
        let other = try make("home/projects/app/node_modules", daysOld: 30)
        let review = try make("tmp/review-colophon05c", daysOld: 10)
        let plain = try make("tmp/unrelated", daysOld: 10)
        o.excludes = [base.appendingPathComponent("home/projects/wt").path, base.path + "/tmp/review-colophon05*"]
        let findings = Scanner.scan(o).findings
        let finding = { (path: String) in findings.first { $0.path == path } }
        XCTAssertEqual(finding(kept)?.tier, .info)
        XCTAssertEqual(finding(kept)?.action, Action.none)
        XCTAssertEqual(finding(review)?.tier, .info)
        XCTAssertEqual(finding(other)?.tier, .safe)
        XCTAssertEqual(finding(plain)?.tier, .safe)

        var request = CleanRequest()
        request.categories = [.artifacts, .tmp]
        request.paths = [kept]
        request.allowReview = true
        request.apply = true
        let removed = Cleaner.clean(findings, request, options: o).map(\.path)
        XCTAssertFalse(removed.contains(kept), "an excluded path cannot be removed even when named")
        XCTAssertTrue(fm.fileExists(atPath: kept))

        // A finding that contains a protected path is protected too.
        o.excludes = [review + "/data.bin"]
        XCTAssertEqual(Scanner.scan(o).findings.first { $0.path == review }?.tier, .info)
    }

    func testTmpWorktreeLeavesThroughGit() throws {
        let o = try options([.tmp])
        let wt = try make("tmp/review-wt", daysOld: 10)
        try "gitdir: /repos/main/.git/worktrees/review-wt\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: wt + "/.git")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: wt)
        let finding = Scanner.scan(o).findings.first { $0.path == wt }
        XCTAssertEqual(finding?.action, .command(["git", "-C", "/repos/main", "worktree", "remove", wt]))
    }
}
