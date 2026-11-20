# devdisk

A small macOS CLI that explains where local development ate the disk and reclaims the part
that is safe to reclaim. It is built for coding agents as much as for people: every command
has `--json`, removal is a dry run by default, and only paths the scanner itself found can be
removed.

## Install

```sh
brew install luff-llc/tap/devdisk
```

Or from source:

```sh
swift build -c release
cp .build/release/devdisk ~/.local/bin/
```

Requires macOS 13 or later and a Swift 5.9+ toolchain. No dependencies.

## Use

```sh
devdisk status                 # free space and pressure: ok | low | critical
devdisk scan                   # what is using space, by category and tier
devdisk scan --category tmp --category xcode --json
devdisk clean --all-safe       # dry run of everything in the safe tier
devdisk clean --all-safe --apply
devdisk clean --path /private/tmp/old-review-clone --allow-review --apply
devdisk guide                  # conventions to paste into AGENTS.md / CLAUDE.md
```

Sizes are measured with `getattrlistbulk` (one system call per directory instead of one per
file) and remembered for an hour in `~/.local/state/devdisk/sizes.json`. A remembered size is
reused only while the folder's own modification time is unchanged; `--no-cache` re-measures
everything. Tiers and ages are always computed fresh.

## Tiers

| Tier | Meaning | Removed by |
| --- | --- | --- |
| `safe` | Regenerable and not recently used | `clean --apply` |
| `review` | Probably removable, needs a decision | `clean --allow-review --apply` |
| `info` | Explains the space; not devdisk's to remove | never |

## Categories

| Category | What it finds |
| --- | --- |
| `tmp` | Your entries in `/private/tmp` and `$TMPDIR`. Safe after 3 idle days unless a process is working inside. |
| `artifacts` | `node_modules`, Cargo `target`, SwiftPM `.build`, `.next`, `Pods`, `DerivedData` under project roots. Safe after 7 idle days. Git-ignored `build`/`dist`/`out` folders are always `review`. |
| `worktrees` | Git worktrees of repos in the project roots. Safe only when clean, merged or pushed, and idle; removed with `git worktree remove`. |
| `xcode` | DerivedData, superseded device-support symbols (newest per device is kept), archives, caches. |
| `simulators` | Simulator devices and runtimes, removed through `xcrun simctl`. |
| `caches` | npm, bun, Gradle, Cargo, CocoaPods, Homebrew, pip, Yarn, SwiftPM, `~/.cache`. |
| `browsers` | Chrome's leftover `code_sign_clone` copies. |
| `agents` | Codex, Claude, Gemini and Cursor transcripts and worktrees; OpenClaw scratch files, spent runtimes, rollback snapshots and idle browser profiles. Projects under `~/.openclaw/workspace/projects` are scanned like any other root. |
| `models` | LM Studio, oMLX, Ollama and Hugging Face model stores. |
| `containers` | Docker, OrbStack, Colima, Lima, Android emulator images. |

Project roots default to whichever of `~/projects`, `~/code`, `~/Developer`, `~/src`, `~/work`,
`~/repos`, `~/dev`, `~/git` exist. Override with `--root` or `DEVDISK_ROOTS=a:b`.

## Simulators

Each booted simulator runs a few hundred processes; two of them can hold most of a 64 GB
machine. `devdisk sim` replaces "create a new simulator per task" with a small shared pool.

```sh
devdisk sim status
devdisk sim acquire --owner "$SESSION_ID" --device-type "iPhone 18 Pro" --boot   # prints a UDID
devdisk sim renew   --owner "$SESSION_ID"
devdisk sim release --owner "$SESSION_ID" [--erase]
devdisk sim reap            # dry run; add --apply
```

- `acquire` only hands out devices it created (named `devdisk-*`), so personal simulators and
  their data are never given to an agent. It creates a new one only below `--pool-max` (3).
- `--boot` is refused when `--max-booted` simulators are already up (default RAM / 32 GB) or
  less than 20% of memory is available.
- Exit code 3 means no capacity. The output (and `--json`) lists the owners holding simulators
  and any booted without a lease, so a coordinator can ask the holder to release.
- Leases expire after `--ttl` (4h) and live in `~/.local/state/devdisk/leases.json`.
- `reap` shuts down unleased simulators booted longer than `--idle` (2h; data is kept) and
  deletes unbootable ones and temporary ones (name contains `temp`/`tmp`) unused for `--temp-age` (1d).

## Protecting work in progress

A finding is never `safe` while it is in use. After every scan devdisk checks the running
processes and demotes a finding to `review` when:

- a process has its working directory inside it, or inside the project that owns a build folder;
- a process names it on its command line (compilers and build tools pass their output paths);
- it is a shared cache and a tool that reads it is running (`~/.cargo/registry` with `cargo` or
  `rustc`, the SwiftPM and Xcode caches with `xcodebuild` or `swift-build`, and so on).

Shared download caches are also `review` until nothing has been added to them for 30 days,
because offline builds need them and reads leave no trace.

Build output is also kept out of the safe tier when a LaunchAgent runs from the same project,
since a job on a timer is rarely running at the moment of the scan.

For anything that must survive between builds, list it in `~/.config/devdisk/exclude`, one path
or glob per line (`#` for comments, `~` for home), or pass `--exclude`. Excluded findings show
as `info` and cannot be removed, even when named with `--path`. A finding that contains an
excluded path is protected too.

Temp folders that are git worktrees are removed with `git worktree remove`, so the repository's
worktree list stays true and git refuses if there are uncommitted changes.

## Safety

- `clean` re-scans and removes only findings from that scan. A `--path` that is not a finding is ignored.
- Direct deletes are refused outside the home and temp directories, and for symbolic links.
- Worktrees and simulators are removed by `git` and `simctl`, which apply their own checks.
- Every removal is appended to `~/Library/Logs/devdisk.log`.
