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

- Open tabs without the mouse: `~/Applications/Nook.app/Contents/MacOS/Nook --show home|clipboard|shelf|ai|notes|mirror|calendar|timer|cuely|power|close`.
  `mirror` turns the camera on (first time: a macOS camera prompt) — do not open it in routine checks.
  Also `--timer <min>|stop|pomodoro`, `--prompt`, `--answer allow|always|deny|terminal`.
- Screenshots: the built-in display is 1800 pt wide, notch centred at x = 900:
  `screencapture -x -R 490,0,820,330 out.png`.
- Animations are too fast to capture: `defaults write dev.nook.app slowMotion -float 10`, restart Nook,
  capture frames, then `defaults delete dev.nook.app slowMotion`.
- Agent hooks: feed events by piping JSON into `~/Library/Application Support/Nook/agent-hook.sh <Event>`.
- Synthetic clicks do not reach the non-activating panel; use the CLI flags above instead of moving the user's mouse.

## Design rules

- Visual system lives in `Sources/Theme.swift` (palette, glass, pills, meters, ambient glow, motion helpers).
  Mockups: Figma "Sandbox", page "Nook" (variant B «Сияние» is the chosen one).
- The band under the camera (notch height) stays pure black in every mode; glow rises from below
  (`AmbientGlow(blackTop:)`). The user asked for this explicitly.
- Animations go through `Motion` (`smooth`, `quick`, `tab`) and respect Reduce Motion.

## Pitfalls

- Never touch files or run AppleScript on the main thread: a first-time macOS permission prompt blocks the
  calling thread and froze the whole notch once. Use the per-service serial queues.
- Inserted SwiftUI content appears at its final size: clip on the persistent container in `RootView`,
  not on the content, or it draws outside the growing notch.
- The agent (Claude Code auto mode) may not edit `~/.claude/settings.json`, LaunchAgents or the keychain;
  ask the user to run `Nook --install-hooks`, the menu item, or `make-cert.sh` with `!`.
- Now Playing: MediaRemote answers nothing to Nook itself (macOS 15.4+). The bridge in `Sources/MediaRemote`
  runs inside `/usr/bin/perl`; `install.sh` builds the dylib with clang and copies it into Resources.
  Test it read-only (`perl nook-media.pl <dylib>` with stdin closed after a few seconds); sending
  `toggle`/`next` would change the user's playback.
- `install.sh` signs with "Nook Local Signing"; macOS may show a keychain prompt for codesign that only the
  user can answer — the build then waits.
- The tab area has a fixed height (`contentHeight`): the notch is 38 pt on this Mac, so a tab gets
  326 − 22 − 32 − 10 = 262 pt. Taller content is clipped; check new cards against that.
- The panel takes the keyboard only for text fields (`becomesKeyOnlyIfNeeded`). Do not make it key on open:
  the user's ⌘1–9 and typing would land in Nook instead of the terminal (this once switched tabs by itself).
- Test questions / plans / permissions by piping a PermissionRequest JSON into `agent-hook.sh` in the
  background, capture, then release with `Nook --answer terminal` and send SessionEnd for the fake session.
- Pointer polling is event-driven: a global mouse-moved monitor starts the 30 Hz `tick`, which stops itself
  when nothing near the notch needs it. Anything new that needs hover (a new floating mode) must call
  `startTicks()` and be listed in `needsTicks`, or it will not react to the pointer.
- Keep idle cost near zero: no always-on timers faster than ~1 s, assign `@Published` values only when they
  change, pause loops with `\.motionPaused`. Endless indicators (dots, music bars) use `LayerLoop`
  (Core Animation): a `TimelineView` re-lays out the whole notch window every frame (~4 % CPU at 12 fps). Measure with
  `top -l 6 -s 5 -pid $(pgrep -x Nook) -stats pid,cpu,idlew,power` (idle target ≤ 0.5 % CPU).
- Only one Nook may run (two copies overwrite each other's files): unknown `--flags` exit with status 2.
- Notification islands read the Notification Center DB (needs Full Disk Access). Its format is unverified on
  macOS 27; `~/Library/Application Support/Nook/notifications-debug.log` lists bundle ids and key names only.
