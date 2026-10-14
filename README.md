# Culprit

A macOS menu bar app that answers one question: **which agent run is using my CPU right now?**

Activity Monitor shows a wall of `node`, `git` and `vitest`. Culprit groups that load by the
repo, worktree and branch it belongs to, and by the coding-agent session (Claude Code, T3 Code)
that spawned it.

## Pausing a session

Each agent row has a pause button. It sends `SIGSTOP` to the whole session, its own `claude`
process included, and the play button sends `SIGCONT`. Pausing only the children would not
work: Claude's Bash tool would time them out and kill them.

Culprit resumes everything it paused when it quits. The paused processes are also recorded in
`~/Library/Application Support/Culprit/paused.json`, and the next launch resumes them, so a
crash cannot leave a session frozen.

A session running as a foreground job in a terminal shell is the one awkward case: the shell
sees the stop, takes the terminal back and prints "suspended". After resuming, type `fg` in
that terminal to bring it back to the foreground. Sessions run by T3 Code or the Claude app
have no shell in between and resume on their own.

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
