# Nook — project guidance

Own macOS notch app (Swift/SwiftUI, no Xcode project). It replaced Notchy. User-facing docs: `README.md`.
Active plan and open items: `docs/exec-plans/active/nook-notch-app.md`.

## Branches and remote

- `main` — stable, what is installed day to day. `develop` — ongoing work; merge to `main` when verified.
- Remote `olehmrvz/nook` is private. Git auth is repo-local (`credential.helper` calls
  `gh auth token --user olehmrvz`), because the active `gh` account is `liva7300` for other projects.
  Never switch the global `gh` account for this repo.

## Build and run

- `./install.sh` — compiles `Sources/*.swift` with `swiftc` (Command Line Tools only), installs
  `~/Applications/Nook.app`, signs it, restarts it. Add new system frameworks to the `swiftc` line there.
- Signing: identity "Nook Local Signing" (created once by `make-cert.sh`) keeps macOS permissions across
  rebuilds; without it the build is ad-hoc and macOS asks for permissions again.
- New permission? Add its usage string to `Info.plist`, or macOS kills the app on first use.

## Checking changes

- Open tabs without the mouse: `~/Applications/Nook.app/Contents/MacOS/Nook --show home|clipboard|shelf|ai|calendar|timer|cuely|close`.
  Also `--timer <min>|stop|pomodoro`, `--prompt`, `--answer allow|always|deny|terminal`.
- Screenshots: the built-in display is 1800 pt wide, notch centred at x = 900:
  `screencapture -x -R 490,0,820,330 out.png`.
- Animations are too fast to capture: `defaults write dev.nook.app slowMotion -float 10`, restart Nook,
  capture frames, then `defaults delete dev.nook.app slowMotion`.
- Agent hooks: feed events by piping JSON into `~/Library/Application Support/Nook/agent-hook.sh <Event>`.
- Synthetic clicks do not reach the non-activating panel; use the CLI flags above instead of moving the user's mouse.

## Pitfalls

- Never touch files or run AppleScript on the main thread: a first-time macOS permission prompt blocks the
  calling thread and froze the whole notch once. Use the per-service serial queues.
- Inserted SwiftUI content appears at its final size: clip on the persistent container in `RootView`,
  not on the content, or it draws outside the growing notch.
- The agent (Claude Code auto mode) may not edit `~/.claude/settings.json`, LaunchAgents or the keychain;
  ask the user to run `Nook --install-hooks`, the menu item, or `make-cert.sh` with `!`.
- Notification islands read the Notification Center DB (needs Full Disk Access). Its format is unverified on
  macOS 27; `~/Library/Application Support/Nook/notifications-debug.log` lists bundle ids and key names only.
