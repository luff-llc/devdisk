enum Guide {
    static let text = """
    ## Disk hygiene (devdisk)

    This machine runs many agent sessions in parallel. Each one that leaves a clone, a build
    folder or a worktree behind costs gigabytes, and nobody else knows it is safe to remove.

    Before heavy work (a fresh clone, a full build, a new simulator or worktree):
    - Run `devdisk status --json`. If `pressure` is `critical`, run `devdisk clean --all-safe --apply`
      first. If it is still critical, stop and tell the user instead of building.

    While working:
    - Put scratch clones and build output under the session's own temp directory, never loose in
      `/tmp` or the home folder. Give the directory a name that says which task owns it.
    - Do not copy a repository to review it. Use `git worktree add`, which shares the object store.
    - Share build caches instead of rebuilding per checkout: one `CARGO_TARGET_DIR`, one Xcode
      DerivedData, the package manager's global store.

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
    - Delete the scratch directories and worktrees you created. You know they are finished;
      no later tool can know that as cheaply.
    - Keep evidence small: keep logs, screenshots and reports, not the build tree that produced them.

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
