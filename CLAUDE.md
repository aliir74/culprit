# Culprit

macOS menu bar app (SwiftUI `MenuBarExtra`) that groups CPU load by coding-agent session, repo,
worktree and app. Attribution is `ClaudeTopKit` from claude-top; this repo is the front end.

## Layout

```
Sources/Culprit/CulpritApp.swift   app entry, AppDelegate, --snapshot renderer
Sources/Culprit/Model.swift        sampling loop, history, stopping leftovers, login item
Sources/Culprit/PanelData.swift    builds rows from one engine reading (off the main actor)
Sources/Culprit/PanelView.swift    all SwiftUI views
Sources/Culprit/ProcInfo.swift     libproc helpers, git repo/branch from .git without spawning git
Scripts/build-app.sh               swift build + .app bundle + ad-hoc sign; --universal for releases
Scripts/install-app.sh             build-app.sh, then install into /Applications
Scripts/package-release.sh         universal build zipped to build/Culprit-<version>.zip
```

## Commands

```bash
./Scripts/install-app.sh                       # build and install, then relaunch the app
swift build                                    # compile check only
.build/release/Culprit --snapshot out.png      # render the panel to a PNG and exit
./Scripts/package-release.sh                   # what CI and the release run
```

`--snapshot` is for checking layout without clicking the menu bar. `ImageRenderer` draws buttons
as yellow placeholders, so it is not good enough for the README screenshot. Take that from the
open panel instead. `screencapture` from an agent shell comes back black when the shell has no
Screen Recording grant or the screen is locked; cua-driver's `get_desktop_state` has its own grant.

## Rules

- Not sandboxed, on purpose: libproc returns `EPERM` inside the App Sandbox.
- claude-top has no tagged releases, so `Package.swift` pins it by revision. Bump the revision
  deliberately and check attribution still works.
- Heavy work (sampling, building rows) runs in `Task.detached`; only results cross back to the
  main actor.
- Stopping leftovers re-reads the machine per group and pins each pid to its start time. Never
  stop from the reading on screen: a pid can be recycled or adopted by a live session meanwhile.
- `install-app.sh` stages and moves the bundle; never overwrite a signed bundle in place.
- Other worktrees of this repo may also install into `/Applications/Culprit.app`. Check
  `pgrep -lf Culprit` and running sessions before replacing it.

## Releasing

1. Bump `VERSION` and add a `## [x.y.z] - date` section to `CHANGELOG.md` in the PR.
2. After merge: `git tag vx.y.z && git push origin vx.y.z`.
3. `release.yml` checks the tag matches `VERSION`, builds the universal zip and publishes a
   GitHub release with that CHANGELOG section as notes.

CI (`ci.yml`) runs the same packaging on every PR and uploads the zip as an artifact.
