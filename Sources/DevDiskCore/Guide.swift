enum Guide {
    static let text = """
    ## Disk hygiene (devdisk)

    This machine runs many agent sessions in parallel. Each one that leaves a clone, a build
    folder or a worktree behind costs gigabytes, and nobody else knows it is safe to remove.

    Before heavy work (a fresh clone, a full build, a new simulator or worktree):
    - Run `devdisk status --json`. `freeBytes` is free right now, the same figure as `df` and
      pressroom's disk floor; `freeIncludingPurgeableBytes` adds space macOS may reclaim later and
      is not something a build can count on. If `pressure` is `critical`, run `devdisk clean --all-safe --apply`
      first. If it is still critical, stop and tell the user instead of building.
    - Before a step that writes a known amount (a Release archive with its own DerivedData is
      2-4 GB), run `devdisk status --need 4G`. It exits 0 when that fits above pressroom's floor,
      and otherwise exits 3 and names the safe findings that would make room, with the exact
      `devdisk clean --path ... --apply` command. Run that command only with the user's go-ahead
      unless your instructions already allow cleaning safe findings.

    While working:
    - Put scratch clones and build output under the session's own temp directory, never loose in
      `/tmp` or the home folder. Give the directory a name that says which task owns it.
    - Do not copy a repository to review it. Use `git worktree add`, which shares the object store.
    - Share build caches instead of rebuilding per checkout: one `CARGO_TARGET_DIR`, one Xcode
      DerivedData, the package manager's global store.
    - Run cargo builds through `pressroom run --lane <repo> --toolchain <the pinned toolchain>
      --holder claude:$CLAUDE_CODE_SESSION_ID`, so output lands in pressroom's shared lane and the
      job is attributed to you. Leaving out `--toolchain` creates a second full lane.
    - Claim every scratch clone, build folder and worktree right after creating it:
      `devdisk claim <path> --kind scratch|build|worktree`. Your session id is the owner. While the
      claim lives (7 days, renewed by claiming again), no other session's cleanup touches it.
    - A subagent shares its session's id. As a subagent, claim with `--scope <your task>` and
      finish with `devdisk finish --scope <your task> --apply`, never `--all`.

    Simulators (each booted one runs hundreds of processes and tens of GB of memory):
    - Never run `xcrun simctl create` or boot a simulator directly. Get one with
      `devdisk sim acquire --owner <your session or task id> --device-type "iPhone 18 Pro" --boot`,
      which prints a UDID from a shared pool and records you as its owner.
    - Exit code 3 means no capacity. The message names the owners holding simulators: wait, or
      ask that session to release. Do not work around it by creating your own.
    - Run `devdisk sim release --owner <id>` as soon as the simulator work is done, and
      `devdisk sim renew --owner <id>` if a task runs past the 4 hour lease.
    - Add `--erase` on release if you installed test data the next owner should not see.

    When the task is done:
    - Give up each worktree as soon as it is merged: `devdisk release <path>`. Mid-session is fine.
    - At the end of the session itself, run `devdisk finish --all --apply` (a subagent: `--scope`).
      It removes what you claimed: build and scratch folders, and worktrees that are clean and
      merged or pushed (others are kept and listed). You know they are finished; no later tool can
      know that as cheaply. A SessionEnd hook may also run it for you. Whatever it removes, its
      builds are then pruned from pressroom's lanes.
    - Release what you hold: `devdisk sim release --owner <id>`, `pressroom lease release <id>`.
    - Keep evidence small: keep logs, screenshots and reports, not the build tree that produced them.

    Builds that stay small:
    - Build Xcode projects into one git-ignored folder in the project:
      `xcodebuild … -derivedDataPath DerivedData.noindex`. The `.noindex` ending keeps Spotlight out.
    - Reuse one named simulator per project and shut it down after each task; erase it rather than
      creating another.

    Protecting work in progress:
    - devdisk never calls something safe while a process is working inside it, names it on its
      command line, or a build tool that reads it (cargo, xcodebuild, swift-build, bun) is running.
    - For anything you are still using, claim it (`devdisk claim`). The exclusion list
      `~/.config/devdisk/exclude` is the user's: use it only when asked. A `!path` line there
      makes an exception inside an excluded folder.

    Cleaning up:
    - `devdisk scan --json` lists findings with a `tier`. `safe` is regenerable and unused;
      `devdisk clean --category <name> --apply` removes it without asking.
    - `review` findings need a reason. Remove one with
      `devdisk clean --path <path> --allow-review --apply` only if you created it in this task
      or the user approved it. Otherwise report it to the user with its size.
    - Never delete `info` findings (models, transcripts, container images) on your own initiative.
    - Do not use `rm -rf` on paths from memory. Remove through devdisk so the path is re-checked
      and the removal is logged in `~/Library/Logs/devdisk.log`.
    """
}
