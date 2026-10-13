# Culprit

A macOS menu bar app that answers one question: **which agent run is using my CPU right now?**

Activity Monitor shows a wall of `node`, `git` and `vitest`. Culprit groups that load by the
repo, worktree and branch it belongs to, and by the coding-agent session (Claude Code, T3 Code)
that spawned it.

## Credits

Attribution comes from `ClaudeTopKit`, the engine of
[claude-top](https://github.com/mbrummerstedt/claude-top) by Martin Brummerstedt (MIT). Culprit
is a different front end over it.

## Build

```bash
./Scripts/install-app.sh   # builds, bundles and copies Culprit.app into /Applications
```

Requires macOS 14+ and Swift 6. The app is not sandboxed: libproc returns EPERM inside the
App Sandbox.
