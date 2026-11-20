import Foundation

/// Answers "can a job that writes `need` bytes start without dropping below the floor?" and,
/// when it cannot, names the safe findings that would make room.
public struct RoomPlan: Codable, Sendable {
    public var freeBytes: Int64
    /// The level nothing new should start below: pressroom's `disk_floor_gb`, else 20 GB.
    public var floorBytes: Int64
    public var needBytes: Int64
    /// Free minus floor covers the need right now.
    public var enough: Bool
    public var shortfallBytes: Int64
    /// Safe findings, largest first, that cover the shortfall; all safe findings if they cannot.
    public var findings: [Finding]
    public var findingsBytes: Int64
    /// Whether cleaning `findings` would cover the shortfall, by measured size. APFS clones
    /// can share blocks, so the space actually freed may be less.
    public var coverable: Bool
    /// The command that removes `findings`.
    public var command: [String]

    /// Pressroom's floor from its `machine.conf`, or 20 GB.
    public static func floor(home: URL) -> Int64 {
        let conf = PressroomLeases.folder(home: home).appendingPathComponent("machine.conf")
        let text = (try? String(contentsOf: conf, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "disk_floor_gb", let gb = Double(parts[1]) { return Int64(gb * Double(1 << 30)) }
        }
        return 20 << 30
    }

    public static func plan(need: Int64, floor: Int64, volume: VolumeStatus, scan: () -> ScanReport) -> RoomPlan {
        let shortfall = max(0, need - (volume.freeBytes - floor))
        var plan = RoomPlan(freeBytes: volume.freeBytes, floorBytes: floor, needBytes: need, enough: shortfall == 0,
                            shortfallBytes: shortfall, findings: [], findingsBytes: 0, coverable: shortfall == 0, command: [])
        guard shortfall > 0 else { return plan }
        var request = CleanRequest()
        request.categories = Set(Category.allCases)
        let safe = Cleaner.select(scan().findings, request).sorted { $0.bytes > $1.bytes }
        for finding in safe where plan.findingsBytes < shortfall {
            plan.findings.append(finding)
            plan.findingsBytes += finding.bytes
        }
        plan.coverable = plan.findingsBytes >= shortfall
        plan.command = ["devdisk", "clean"] + plan.findings.flatMap { ["--path", $0.path] } + ["--apply"]
        return plan
    }
}
