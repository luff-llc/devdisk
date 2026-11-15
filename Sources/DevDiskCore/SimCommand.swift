import Foundation

enum SimCommand {
    static let usage = """
    devdisk sim: share a small pool of simulators instead of creating one per task

    USAGE
      devdisk sim status  [--json]
      devdisk sim acquire --owner <id> --device-type <name> [--runtime <name>] [--boot] [--ttl 4h] [--json]
      devdisk sim renew   --owner <id> [--ttl 4h]
      devdisk sim release (--owner <id> | --udid <udid>) [--erase] [--keep-booted]
      devdisk sim reap    [--apply] [--idle 2h] [--temp-age 1d] [--json]

    acquire  hands out a pooled simulator (named devdisk-*), creating one only while the pool is
             below its cap. Prints the UDID. Exit 3 means no capacity: the output names the
             owners holding it, so the caller can wait or ask them to release.
    release  ends the lease and shuts the simulator down; it stays in the pool for the next owner.
    reap     shuts down unleased simulators booted longer than --idle, and deletes temporary
             (name contains temp/tmp) or unbootable ones. A dry run unless --apply is given.

    LIMITS
      --max-booted <n>   booted simulators allowed at once (default RAM/32GB, or $DEVDISK_MAX_BOOTED)
      --pool-max <n>     pooled devices per device type and runtime (default 3)

    Leases are kept in ~/.local/state/devdisk/leases.json. The owner is any stable id for the
    session or task doing the work; it is what a coordinator uses to reach the holder.
    """

    private struct StatusRow: Codable {
        var device: SimDevice
        var usage: SimUsage?
        var owner: String?
        var leaseExpiresAt: Date?
    }

    private struct Status: Codable {
        var booted: Int
        var maxBooted: Int
        var memoryAvailablePercent: Int?
        var residentBytes: Int64
        var devices: [StatusRow]
    }

    private struct Acquired: Codable {
        var udid: String
        var name: String
        var owner: String
        var booted: Bool
        var created: Bool
        var expiresAt: Date
    }

    private struct Refusal: Codable, Error {
        var error: String
        var message: String
        var holders: [Lease]
        var unownedBooted: [String]
    }

    static func run(_ arguments: [String], store: LeaseStore = LeaseStore()) -> Int32 {
        guard let verb = arguments.first, verb != "help", verb != "--help" else {
            print(usage)
            return 0
        }
        var args = Array(arguments.dropFirst())
        var limits = SimLimits()
        var owner: String?, deviceType: String?, runtime: String?, udid: String?
        var json = false, boot = false, apply = false, erase = false, keepBooted = false

        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("devdisk: \(message)\n".utf8))
            return 2
        }
        while !args.isEmpty {
            let flag = args.removeFirst()
            func value() -> String? { args.isEmpty ? nil : args.removeFirst() }
            switch flag {
            case "--json": json = true
            case "--boot": boot = true
            case "--apply": apply = true
            case "--erase": erase = true
            case "--keep-booted": keepBooted = true
            case "--owner": owner = value()
            case "--device-type": deviceType = value()
            case "--runtime": runtime = value()
            case "--udid": udid = value()
            case "--ttl":
                guard let t = value().flatMap(parseDuration) else { return fail("--ttl needs a duration such as 4h") }
                limits.leaseTTL = t
            case "--idle":
                guard let t = value().flatMap(parseDuration) else { return fail("--idle needs a duration such as 2h") }
                limits.idle = t
            case "--temp-age":
                guard let t = value().flatMap(parseDuration) else { return fail("--temp-age needs a duration such as 1d") }
                limits.tempAge = t
            case "--max-booted":
                guard let n = value().flatMap(Int.init), n > 0 else { return fail("--max-booted needs a positive number") }
                limits.maxBooted = n
            case "--pool-max":
                guard let n = value().flatMap(Int.init), n > 0 else { return fail("--pool-max needs a positive number") }
                limits.poolMax = n
            default: return fail("unknown option \(flag); run `devdisk sim help`")
            }
        }
        let now = Date()

        switch verb {
        case "status":
            let devices = SimHost.devices()
            let usage = SimHost.usage()
            let leases = SimPlanner.active(store.read(), now: now)
            let rows = devices.map { d -> StatusRow in
                let lease = leases.first { $0.id == d.udid }
                return StatusRow(device: d, usage: usage[d.udid], owner: lease?.owner, leaseExpiresAt: lease?.expiresAt)
            }
            let status = Status(booted: devices.filter(\.isBooted).count, maxBooted: limits.maxBooted,
                                memoryAvailablePercent: SimHost.memoryLevel(),
                                residentBytes: usage.values.reduce(0) { $0 + $1.residentBytes }, devices: rows)
            if json { emit(status) } else { printStatus(status, now: now) }
            return 0

        case "acquire":
            guard let owner, !owner.isEmpty else { return fail("acquire needs --owner") }
            guard let deviceType else { return fail("acquire needs --device-type, for example \"iPhone 18 Pro\"") }
            guard let resolved = SimHost.resolve(deviceType: deviceType, runtime: runtime) else {
                return fail("no installed runtime supports device type \(deviceType)\(runtime.map { " on \($0)" } ?? "")")
            }
            // Selection and the lease write happen under one lock so two agents cannot take the same device.
            let outcome: Result<Acquired, Refusal> = store.mutate { leases in
                leases.removeAll { $0.expiresAt <= now }
                var devices = SimHost.devices()
                var created = false
                var device: SimDevice
                switch SimPlanner.pick(devices: devices, leases: leases, owner: owner, deviceType: resolved.type,
                                       runtime: resolved.runtime, limits: limits, now: now) {
                case .held(let d), .reuse(let d):
                    device = d
                case .create(let name):
                    let made = SimHost.simctl("create", name, resolved.type, resolved.runtime)
                    let newID = made.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard made.status == 0, !newID.isEmpty else {
                        return .failure(Refusal(error: "create-failed", message: "simctl could not create \(name)", holders: [], unownedBooted: []))
                    }
                    devices = SimHost.devices()
                    guard let d = devices.first(where: { $0.udid == newID }) else {
                        return .failure(Refusal(error: "create-failed", message: "created \(name) but simctl does not list it", holders: [], unownedBooted: []))
                    }
                    device = d
                    created = true
                case .full(let holders):
                    return .failure(Refusal(error: "pool-full",
                                            message: "all \(limits.poolMax) pooled \(deviceType) simulators are leased",
                                            holders: holders, unownedBooted: []))
                }
                if boot, !device.isBooted {
                    if let reason = SimPlanner.bootRefusal(devices: devices, memoryLevel: SimHost.memoryLevel(), limits: limits) {
                        let live = SimPlanner.active(leases, now: now)
                        let booted = devices.filter(\.isBooted)
                        return .failure(Refusal(
                            error: "boot-refused", message: reason,
                            holders: live.filter { lease in booted.contains { $0.udid == lease.id } },
                            unownedBooted: booted.filter { d in !live.contains { $0.id == d.udid } }.map(\.name)))
                    }
                    SimHost.simctl("boot", device.udid)
                    guard SimHost.simctl("bootstatus", device.udid, "-b").status == 0 else {
                        return .failure(Refusal(error: "boot-failed", message: "\(device.name) did not finish booting", holders: [], unownedBooted: []))
                    }
                    device.state = "Booted"
                }
                let expires = now.addingTimeInterval(limits.leaseTTL)
                leases.removeAll { $0.kind == "simulator" && $0.id == device.udid }
                leases.append(Lease(owner: owner, kind: "simulator", id: device.udid, createdAt: now, expiresAt: expires))
                return .success(Acquired(udid: device.udid, name: device.name, owner: owner, booted: device.isBooted,
                                         created: created, expiresAt: expires))
            }
            switch outcome {
            case .success(let acquired):
                if json { emit(acquired) } else { print(acquired.udid) }
                return 0
            case .failure(let refusal):
                if json { emit(refusal) } else {
                    var lines = ["devdisk: no simulator available: \(refusal.message)"]
                    for lease in refusal.holders {
                        lines.append("  held by \(lease.owner) for another \(formatDuration(lease.expiresAt.timeIntervalSince(now))); ask them to run `devdisk sim release --owner \(lease.owner)`")
                    }
                    if !refusal.unownedBooted.isEmpty {
                        lines.append("  booted with no lease: \(refusal.unownedBooted.joined(separator: ", ")); `devdisk sim reap` can shut idle ones down")
                    }
                    FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                }
                return 3
            }

        case "renew":
            guard let owner else { return fail("renew needs --owner") }
            let count: Int = store.mutate { leases in
                var n = 0
                for i in leases.indices where leases[i].owner == owner && leases[i].expiresAt > now {
                    leases[i].expiresAt = now.addingTimeInterval(limits.leaseTTL)
                    n += 1
                }
                return n
            }
            print("renewed \(count) lease\(count == 1 ? "" : "s") for \(formatDuration(limits.leaseTTL))")
            return count > 0 ? 0 : 1

        case "release":
            guard owner != nil || udid != nil else { return fail("release needs --owner or --udid") }
            let released: [Lease] = store.mutate { leases in
                let match = leases.filter { $0.kind == "simulator" && ($0.owner == owner || $0.id == udid) }
                leases.removeAll { match.contains($0) }
                return match
            }
            for lease in released {
                if !keepBooted { SimHost.simctl("shutdown", lease.id) }
                if erase {
                    SimHost.simctl("shutdown", lease.id)
                    SimHost.simctl("erase", lease.id)
                }
                print("released \(lease.id) (\(lease.owner))\(keepBooted ? "" : ", shut down")\(erase ? ", erased" : "")")
            }
            if released.isEmpty { print("no matching lease") }
            return 0

        case "reap":
            let leases: [Lease] = store.mutate { leases in
                if apply { leases.removeAll { $0.expiresAt <= now } }
                return leases
            }
            var actions = SimPlanner.reap(devices: SimHost.devices(), usage: SimHost.usage(), leases: leases, limits: limits, now: now)
            if apply {
                for i in actions.indices {
                    let ok: Bool
                    if actions[i].action == "shutdown" {
                        ok = SimHost.simctl("shutdown", actions[i].udid).status == 0
                    } else {
                        ok = SimHost.simctl("delete", actions[i].udid).status == 0
                    }
                    actions[i].outcome = ok ? "done" : "failed"
                }
            }
            if json { emit(actions) } else { printReap(actions, apply: apply) }
            return actions.contains { $0.outcome == "failed" } ? 1 : 0

        default:
            return fail("unknown sim command \(verb); run `devdisk sim help`")
        }
    }

    private static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? String(text.prefix(width)) : text + String(repeating: " ", count: width - text.count)
    }

    private static func printStatus(_ status: Status, now: Date) {
        let memory = status.memoryAvailablePercent.map { ", \($0)% of memory available" } ?? ""
        print("\(status.booted) of \(status.maxBooted) allowed simulators booted, \(formatBytes(status.residentBytes)) resident\(memory)\n")
        print("  \(pad("NAME", 34)) \(pad("STATE", 9)) \(pad("MEMORY", 8)) \(pad("PROCS", 6)) \(pad("UP", 7)) \(pad("DISK", 7)) \(pad("LAST USED", 10)) OWNER")
        for row in status.devices {
            let d = row.device
            let used = d.lastUsedAt.map { formatDuration(now.timeIntervalSince($0)) + " ago" } ?? "never"
            let owner = row.owner.map { "\($0) (\(formatDuration((row.leaseExpiresAt ?? now).timeIntervalSince(now))) left)" } ?? "-"
            print("  \(pad(d.name, 34)) \(pad(d.isAvailable ? d.state : "Unusable", 9)) \(pad(row.usage.map { formatBytes($0.residentBytes) } ?? "-", 8)) \(pad(row.usage.map { String($0.processes) } ?? "-", 6)) \(pad(row.usage.map { formatDuration($0.bootedSeconds) } ?? "-", 7)) \(pad(formatBytes(d.dataBytes), 7)) \(pad(used, 10)) \(owner)")
        }
        print("\nMemory is summed per process, so shared pages are counted more than once.")
    }

    private static func printReap(_ actions: [ReapAction], apply: Bool) {
        if actions.isEmpty {
            print("Nothing to reap.")
            return
        }
        for a in actions {
            print("  \(pad(apply ? a.outcome : "would", 7)) \(pad(a.action, 9)) \(pad(a.name, 44)) \(a.reason)")
        }
        let disk = actions.filter { $0.action == "delete" }.reduce(Int64(0)) { $0 + $1.bytes }
        let memory = actions.filter { $0.action == "shutdown" }.reduce(Int64(0)) { $0 + $1.residentBytes }
        print("\n\(apply ? "Freed" : "Dry run: would free") about \(formatBytes(disk)) of disk and \(formatBytes(memory)) of resident memory.\(apply ? "" : " Re-run with --apply.")")
    }
}
