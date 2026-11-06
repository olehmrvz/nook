# Nook — development

Native Swift/SwiftUI, no Xcode project: `swiftc` from Command Line Tools builds `Sources/*.swift`.
User-facing overview: [README.md](../README.md). Project rules for coding agents: [CLAUDE.md](../CLAUDE.md).

## Build and install

`./install.sh` builds with the Swift compiler from Command Line Tools, installs `/Applications/Nook.app`
and starts it. It signs with the first of: `NOOK_SIGN_IDENTITY`, a Developer ID Application certificate in the
keychain, "Nook Local Signing" from `make-cert.sh`, ad-hoc. The version is the number of commits (`1.<count>`).
`./release.sh` publishes the current commit as a GitHub release (see Releases); every installed Nook picks it
up within 6 hours, checks the signature, and installs it when the panel is closed. Menu bar icon → Launch at
login (Запускать при входе) adds a LaunchAgent `~/Library/LaunchAgents/dev.nook.app.plist`.

## Releases

A release is signed with Nook's Developer ID (team `T2KMY2TV9W`), notarized by Apple and stapled, so a
download opens without "unidentified developer" warnings. Assets: `Nook.dmg` (drag to Applications) and
`Nook.zip` (read by the updater). The updater accepts a build that satisfies the running copy's designated
requirement or `Updater.releaseRequirement` (Developer ID of team `T2KMY2TV9W`, bundle id `dev.nook.app`);
the requirement names the team, so a renewed certificate keeps updates working. The second requirement is
used only by copies signed like the old releases (`Updater.legacyRequirement`, "Nook Local Signing" of this
repository). A contributor's build (ad-hoc or another certificate) takes only builds signed like itself, so a
release never replaces it.

One-time setup on the release Mac (needs the paid Apple Developer Program; the account holder does it):
1. Developer ID Application certificate: Xcode → Settings → Accounts → the Apple ID → team "Oleh Yaitsov" →
   Manage Certificates… → + → Developer ID Application. Back up the certificate with its private key
   (Keychain Access → My Certificates → Export, a `.p12` with a password) somewhere safe.
2. App-specific password: account.apple.com → Sign-In and Security → App-Specific Passwords.
3. Notary credentials in the keychain, in Terminal (it asks for that password):
   `xcrun notarytool store-credentials nook --apple-id <Apple ID e-mail> --team-id T2KMY2TV9W`
   (another profile name: `NOOK_NOTARY_PROFILE`).

`./release.sh` then builds with a secure timestamp, notarizes the app (zip) and staples it, builds and
notarizes `Nook.dmg`, checks both with `spctl`, and publishes. Notarization takes a few minutes; on a
rejection the script prints Apple's log and publishes nothing.

Copies released before Developer ID (v10 and earlier, signed with "Nook Local Signing") accept only that
certificate. Move them once with a bridge release: `./release.sh --local-signing` (old signing, not notarized)
ships the updater that also accepts Developer ID builds; the next `./release.sh` is notarized. A copy that
skipped the bridge keeps working but does not update: download `Nook.dmg` once by hand.
macOS ties granted permissions to the signature. After the update to Developer ID it may ask again for Calendar,
Contacts, camera and the like; Full Disk Access and Accessibility stay switched on in System Settings but stop
working until Nook is turned off and on there. `release.sh` puts this in the notes of the first notarized release
(the previous release is not notarized); the same applies to your own copy after the first Developer ID build.

Hooks: connected automatically on first launch for each agent found (`~/.claude`, `~/.codex`), once — hooks
removed later are not put back. By hand: menu → Agents (Агенты) → Connect (Подключить), or `Nook --install-hooks`. For Codex,
Nook also sets `[features] hooks = true` in `~/.codex/config.toml`. This adds Nook's hook to
`~/.claude/settings.json` and `~/.codex/hooks.json`, removes Notchy's hooks, keeps all other hooks and saves
`*.bak-nook` (the original, kept) and `*.bak-nook-prev` (before the latest change), owner-only, first.

## Permissions

Notifications and calls read the Notification Center database and need **Full Disk Access** for Nook.
Calendar, Contacts, Bluetooth, Location, Microphone/Speech are asked when first used.
`install.sh` keeps these grants across rebuilds when it signs with a stable identity: a Developer ID certificate,
or "Nook Local Signing" (run `./make-cert.sh` once; it asks for your password to trust the certificate).
Without either each rebuild is ad-hoc signed and macOS may ask again.

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
- Reply to an agent (`ReplyField`, `AgentHub.reply`): only for sessions in herdr (`pane send-text` + `send-keys enter`)
  or tmux (`send-keys -l`), and only when the session is done or idle — never while a request or a terminal dialog
  may be open. One line; no command-line flag for it (an agent must not type into another agent through Nook).
- Turn summary: edited files, test runs and `git commit` / `git push` from `PreToolUse` Bash commands, with the
  result from `PostToolUse` / `PostToolUseFailure` (Claude only; Nook adds that event to an existing hook setup).
- Usage (`Sources/Usage.swift`): Claude transcripts changed today, read incrementally in 4 MB chunks, deduplicated by
  message id + request id; cost at API list prices (table in the file). Codex sessions show no tokens yet.
- Process watch (`Sources/Processes.swift`): own processes, sampled every 10 s; island at ≥ 90 % CPU for 2 min or
  ≥ 4 GB memory, once per process per hour. "Завершить" needs a second click; it checks the start time first.
- Focus mode (Timer tab or `Nook --timer focus`): Pomodoro + coffee; notification islands are dropped during focus
  phases (calls still show); `--timer stop` ends it and restores coffee.
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
  it is signed by Nook (`signedByNook`: the running app's designated requirement or Nook's Developer ID), and
  installs it when the panel is closed.
- **Volume:** `Sources/Volume.swift` watches the default output device (CoreAudio). With Accessibility access it
  also takes the volume keys (event tap on NX_SYSDEFINED), sets the level itself in 1/16 steps (⌥⇧: 1/64), so the
  macOS HUD does not appear. Without access the keys stay with macOS and Nook only shows the change.
- **Brightness:** built-in display via DisplayServices (private). Shown only after a brightness key, never for
  automatic brightness. **Focus / Do Not Disturb:** `Sources/Focus.swift` watches `~/Library/DoNotDisturb/DB`
  (needs Full Disk Access) with file-system events, no polling; `focus-debug.log` records structure only.
- **Pointer:** event-driven polling; the panel takes the keyboard only for text fields.
