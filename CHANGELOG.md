# Changelog

Versions follow [Semantic Versioning](https://semver.org). Each release's notes on GitHub are
its section below.

## [Unreleased]

### Fixed

- Agent sessions show again when Culprit is opened from Finder or as a login item. That
  launch gets a `PATH` without `~/.local/bin`, so the native `claude` install was never
  found, the session list came back empty, and every session was filed under leftovers.
- The core bar in the panel now uses the same color as the menu bar icon. Before, a long run
  queue turned the icon red while the bar stayed orange or green.

## [0.1.0] - 2026-10-14

First release.

- Menu bar shows how busy the CPU is, coloured green, orange or red, as core columns,
  a history graph, a ring, the busiest app's icon with a meter, or a percentage.
- Agents: each coding-agent session (Claude Code, T3 Code) with its repo, worktree and
  branch, CPU and memory, and a sparkline of the last minute or so.
- Click an agent row to see the folders its processes run in; click a folder to open it in Finder.
- Pause and resume an agent session; Culprit resumes anything it paused when it quits or
  on its next launch.
- Leftovers: process groups and Compose containers whose session has ended, with a button
  to stop them. Live sessions' processes and containers, and Culprit itself, are never stopped.
- Other apps: everything else, grouped by the app bundle it belongs to.
- Refresh interval setting and a start-at-login toggle.
- Universal build (Apple silicon and Intel), macOS 14 or later.
