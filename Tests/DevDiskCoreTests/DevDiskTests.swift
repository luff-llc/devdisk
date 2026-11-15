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
}
