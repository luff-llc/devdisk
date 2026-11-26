import Foundation

/// `devdisk sweep`: the timed part of keeping build lanes small. Pressroom decides what may go
/// and holds each slot while it goes (its rules 32 to 35); this only runs it, and runs it on a
/// timer, because builds fill lanes faster than sessions end.
enum SweepCommand {
    static let label = "works.luff.devdisk-sweep"
    static let usage = """
    devdisk sweep [--apply] [--json]
        Run `pressroom prune`: remove from pressroom's build lanes the builds of worktrees that
        are gone and, over the lane budget (lane_budget_gb in pressroom's machine.conf), older
        builds and those of the least recently used worktrees. Only slots no build holds.
        A dry run unless --apply.
    devdisk sweep --install [--every 1h]
        Run `devdisk sweep --apply` on a timer, from a LaunchAgent (\(label)).
        Its output goes to ~/Library/Logs/devdisk-sweep.log.
    devdisk sweep --uninstall
        Remove that LaunchAgent.
    """

    static func run(_ arguments: [String]) -> Int32 {
        var apply = false, json = false, install = false, uninstall = false
        var every: TimeInterval = 3600
        var args = arguments
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("devdisk: \(message)\n".utf8))
            return 2
        }
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--apply": apply = true
            case "--json": json = true
            case "--install": install = true
            case "--uninstall": uninstall = true
            case "--every":
                guard let value = args.first.flatMap(parseDuration), value >= 300 else { return fail("--every needs a duration of at least 5m") }
                args.removeFirst()
                every = value
            case "help", "--help": print(usage); return 0
            default: return fail("unknown option \(arg)")
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let plist = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let domain = "gui/\(getuid())"
        if uninstall {
            _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 30)
            try? FileManager.default.removeItem(at: plist)
            print("removed \(plist.path)")
            return 0
        }
        if install {
            let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
            let program = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/devdisk") ? "/opt/homebrew/bin/devdisk" : me
            let text = agentPlist(program: program, every: Int(every), log: home.appendingPathComponent("Library/Logs/devdisk-sweep.log").path)
            do {
                try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: plist, atomically: true, encoding: .utf8)
            } catch {
                return fail("cannot write \(plist.path): \(error.localizedDescription)")
            }
            _ = Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 30)
            let loaded = Shell.run("/bin/launchctl", ["bootstrap", domain, plist.path], timeout: 30)
            print(loaded.status == 0 ? "installed \(plist.path): devdisk sweep --apply every \(formatDuration(every))"
                                     : "wrote \(plist.path), but launchctl bootstrap exited \(loaded.status)")
            return loaded.status == 0 ? 0 : 1
        }
        guard let tool = Rules.pressroomTool() else { return fail("pressroom is not installed; there are no lanes to sweep") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["prune", "--holder", "devdisk"] + (apply ? ["--apply"] : []) + (json ? ["--json"] : [])
        do { try process.run() } catch { return fail("cannot run \(tool): \(error.localizedDescription)") }
        process.waitUntilExit()
        if !json { print("(\(ISO8601DateFormatter().string(from: Date())))") }
        return process.terminationStatus
    }

    static func agentPlist(program: String, every: Int, log: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(program)</string><string>sweep</string><string>--apply</string></array>
            <key>StartInterval</key><integer>\(every)</integer>
            <key>RunAtLoad</key><false/>
            <key>ProcessType</key><string>Background</string>
            <key>LowPriorityIO</key><true/>
            <key>Nice</key><integer>10</integer>
            <key>StandardOutPath</key><string>\(log)</string>
            <key>StandardErrorPath</key><string>\(log)</string>
        </dict>
        </plist>

        """
    }
}
