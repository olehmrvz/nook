# Nook — development

Native Swift/SwiftUI, no Xcode project: `swiftc` from Command Line Tools builds `Sources/*.swift`.
User-facing overview: [README.md](../README.md). Project rules for coding agents: [CLAUDE.md](../CLAUDE.md).

## Build and install

`./install.sh` builds with the Swift compiler from Command Line Tools, installs `/Applications/Nook.app`
(signed with "Nook Local Signing" from `make-cert.sh`, ad-hoc without it) and starts it. The version is the
number of commits (`1.<count>`). `./release.sh` publishes the current commit as a GitHub release; every
installed Nook picks it up within 6 hours, checks that it is signed with the same certificate, and installs it
when the panel is closed. Menu bar icon → Launch at login (Запускать при входе) adds a LaunchAgent
`~/Library/LaunchAgents/dev.nook.app.plist`.

Hooks: connected automatically on first launch for each agent found (`~/.claude`, `~/.codex`), once — hooks
removed later are not put back. By hand: menu → Agents (Агенты) → Connect (Подключить), or `Nook --install-hooks`. For Codex,
Nook also sets `[features] hooks = true` in `~/.codex/config.toml`. This adds Nook's hook to
`~/.claude/settings.json` and `~/.codex/hooks.json`, removes Notchy's hooks, keeps all other hooks and saves
a `*.bak-nook` copy (owner-only) first.

## Permissions

Notifications and calls read the Notification Center database and need **Full Disk Access** for Nook.
Calendar, Contacts, Bluetooth, Location, Microphone/Speech are asked when first used.
Run `./make-cert.sh` once (asks for your password to trust the certificate): `install.sh` then signs with the
stable "Nook Local Signing" identity, so macOS keeps these grants across rebuilds. Without it each rebuild
is ad-hoc signed and macOS may ask again.

## Command line

`Nook --show home|clipboard|shelf|ai|notes|mirror|calendar|timer|cuely|power|close` opens a tab of the running
app (`power` opens Home with the battery card).
`Nook --timer 25|stop|pomodoro` and `Nook --prompt` (start Cuely) for Raycast / Shortcuts.
`Nook --answer allow|always|deny|terminal` answers the oldest pending agent request. It works from your own
terminal, not from a process an agent started (an agent must not approve its own request).

## Notes

- Data: `~/Library/Application Support/Nook` (clipboard.json, notes.json and sessions.json are mode 600).
  `clipboard.json.bak` is a safety copy (hourly, and before an unexplained large drop); entries you delete
  leave it too. `clipboard-events.log` records loads, deletes and clears with counts only, never content.
- The panel closes by itself after 2 minutes without input and while the screen is locked or asleep.
- Menu: the menu bar icon, or ⚙︎ in the panel header (the icon can be hidden; opening Nook.app again brings it
  back). Display (Экран): pick the display for the notch (on a display without a notch it is a small pill).
- ☕ in the header: "coffee" keeps the Mac awake while idle (agents left working). The display still sleeps.
- `notifications-debug.log` in the data folder records bundle ids and key names (never message text) of the
  first 40 notifications, to check the database format on new macOS versions.

## How parts work

- **Now Playing** comes from the system (MediaRemote) through `Sources/MediaRemote`: a small dylib loaded into
  Apple's `/usr/bin/perl`, because macOS 15.4+ answers MediaRemote only to Apple-signed processes. Nook starts
  the bridge only when its own signature (which seals the dylib and script) is intact. If the bridge fails,
  AppleScript covers Spotify and Music.
- **Agents:** Claude Code and Codex hooks call `agent-hook.sh`, which sends the event over an owner-only unix
  socket with a random token. Permission requests wait for the answer in the notch (110 s, then the terminal).
- **Updates:** `Sources/Updater.swift` reads the latest GitHub release, downloads `Nook.zip`, accepts it only if
  it satisfies the running app's designated requirement (same bundle id and certificate), and installs it when
  the panel is closed.
- **Volume:** `Sources/Volume.swift` watches the default output device (CoreAudio). With Accessibility access it
  also takes the volume keys (event tap on NX_SYSDEFINED), sets the level itself in 1/16 steps (⌥⇧: 1/64), so the
  macOS HUD does not appear. Without access the keys stay with macOS and Nook only shows the change.
- **Brightness:** built-in display via DisplayServices (private). Shown only after a brightness key, never for
  automatic brightness. **Focus / Do Not Disturb:** `Sources/Focus.swift` watches `~/Library/DoNotDisturb/DB`
  (needs Full Disk Access) with file-system events, no polling; `focus-debug.log` records structure only.
- **Pointer:** event-driven polling; the panel takes the keyboard only for text fields.
