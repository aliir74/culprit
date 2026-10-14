# Changelog

Versions follow [Semantic Versioning](https://semver.org). Each release's notes on GitHub are
its section below.

## [0.1.0] - 2026-10-13

First release.

- Menu bar title shows how busy the CPU is, coloured green, orange or red.
- Agents: each coding-agent session (Claude Code, T3 Code) with its repo, worktree and
  branch, CPU and memory, and a sparkline of the last minute or so.
- Click an agent row to see the folders its processes run in; click a folder to open it in Finder.
- Leftovers: process groups whose session has ended, with a button to stop them. Live
  sessions and Culprit itself are never stopped.
- Other apps: everything else, grouped by the app bundle it belongs to.
- Refresh interval setting and a start-at-login toggle.
- Universal build (Apple silicon and Intel), macOS 14 or later.
