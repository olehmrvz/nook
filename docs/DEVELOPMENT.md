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
`*.bak-nook` (the original, kept) and `*.bak-nook-prev` (before the latest change), owner-only, first.

## Permissions

Notifications and calls read the Notification Center database and need **Full Disk Access** for Nook.
Calendar, Contacts, Bluetooth, Location, Microphone/Speech are asked when first used.
Run `./make-cert.sh` once (asks for your password to trust the certificate): `install.sh` then signs with the
stable "Nook Local Signing" identity, so macOS keeps these grants across rebuilds. Without it each rebuild
is ad-hoc signed and macOS may ask again.

## Command line

`Nook --show home|clipboard|shelf|ai|notes|mirror|calendar|timer|cuely|power|close` opens a tab of the running
app (`power` opens Home with the battery card); `Nook --show settings[:pane]` opens the Settings window
(panes: general, notch, notifications, dictation, agents, privacy, updates, thanks).
`Nook --show launcher` opens the search with the keyboard in it; `Nook --show launcher:<text>` shows the results for
`<text>` without taking the keyboard (for checks: typing keeps going to the app in front).
`Nook --dictate [start|stop|cancel|toggle]` drives dictation; it is refused from processes an agent started
(they would hear the person and get the text typed into their own terminal), like `--answer`.
`Nook --timer 25|stop|pomodoro` and `Nook --prompt` (start Cuely) for Raycast / Shortcuts.
`Nook --answer allow|always|deny|terminal` answers the oldest pending agent request. It works from your own
terminal, not from a process an agent started (an agent must not approve its own request).

## Notes

- Data: `~/Library/Application Support/Nook` (clipboard.json, notes.json and sessions.json are mode 600).
  `clipboard.json.bak` is a safety copy (hourly, and before an unexplained large drop); entries you delete
  leave it too. `clipboard-events.log` records loads, deletes and clears with counts only, never content.
- The panel closes by itself after 2 minutes without input and while the screen is locked or asleep.
- Settings (`Sources/SettingsWindow.swift`): a normal window opened by ⚙︎ in the panel header, the menu bar icon
  (Настройки… ⌘,) or `Nook --show settings[:pane]`. The menu bar menu keeps quick actions only; the icon can be
  hidden (opening Nook.app again brings it back). Display (Экран): pick the display for the notch (on a display
  without a notch it is a small pill). Permission status there reads live state (AXIsProcessTrusted, whether the
  notification database opens), because a toggle in System Settings can look on while it does not work.
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
  it satisfies the running app's designated requirement (same bundle id and certificate), and installs it when
  the panel is closed.
- **Volume:** `Sources/Volume.swift` watches the default output device (CoreAudio). With Accessibility access it
  also takes the volume keys (event tap on NX_SYSDEFINED), sets the level itself in 1/16 steps (⌥⇧: 1/64), so the
  macOS HUD does not appear. Without access the keys stay with macOS and Nook only shows the change.
- **Brightness:** built-in display via DisplayServices (private). Shown only after a brightness key, never for
  automatic brightness. **Focus / Do Not Disturb:** `Sources/Focus.swift` watches `~/Library/DoNotDisturb/DB`
  (needs Full Disk Access) with file-system events, no polling; `focus-debug.log` records structure only.
- **Pointer:** event-driven polling; the panel takes the keyboard only for text fields.
- **Search (launcher):** `Sources/Launcher.swift`. ⌥Space or the recorded shortcut (`ShortcutRecorder.swift`,
  Carbon hot key id 2) opens the `.launcher` tab on the display with the pointer; the panel moves back when it closes.
  Index off the main thread, again when older than a minute: apps in /Applications (hidden links too: Safari lives
  in /System/Cryptexes), /System/Applications, ~/Applications; System Settings panes from
  /System/Library/ExtensionKit/Extensions (`com.apple.Settings.extension.ui`, names in the system language thanks to
  `CFBundleAllowMixedLocalizations`); Nook's commands. Ranking: exact, prefix, word start, initials, substring,
  letters in order; the query is also tried in the other keyboard layout (ЙЦУКЕН ↔ QWERTY); usage boost from
  `launcherUsage` (count, last use). Opening an app does not hand focus back to the previous app first, so the new
  window lands on the display the search was on.
- **Search sources:** `Sources/LauncherSources.swift`. Apple Shortcuts: `shortcuts list --show-identifiers` at index
  time (5 s cap), `shortcuts run <id>`. Files: `NSMetadataQuery` on the name in the home folder, 0.15 s after typing
  stops, from 3 characters, top 5 (no `.app`, no `Library`); icons by file type, never read from the file (a file in
  Documents could ask for a permission). Emoji: macOS's own names from CoreEmoji `AppleName.strings` (system
  language + English), `:` starts an emoji search. Quicklinks `[name, URL with {query}]` and custom commands
  `[name, zsh text]` are lists in the settings; commands run `zsh -lc` in the home folder with `NOOK=1`.
- **Windows:** `Sources/Windows.swift`. Commands are search items (`window:<action>`), so aliases and item shortcuts
  apply. AX off the main thread on the front app's focused window: visible frame of its display (Dock, menu bar,
  notch excluded), edges rounded separately, size → position → size. Restore keeps the frame from before the first
  command of a chain; a window moved by hand (> 2 pt) starts a new chain. Minimized and full-screen windows are skipped.
- **Snippets:** `Sources/Snippets.swift`. One `.md` per snippet in `Snippets/` (front matter: name, keyword,
  enabled). A listen-only key tap (only with Settings → Сниппеты on and Accessibility) keeps ≤ 256 typed characters
  in memory; shortcuts, navigation keys, an app switch, Secure Event Input or 15 s of quiet clear it. The longest
  keyword at the end fires on the next main-loop turn: backspaces, then the text (`TextInsertion`: typed as key
  events up to 100 characters on one line, else pasted with the clipboard restored). Nook's own events carry
  `eventSourceUserData = TextInsertion.tag` and are ignored by the tap.
- **Header:** Settings → Панель hides tabs and buttons (`Settings.headerHidden`); the gear always stays. With three
  tabs or fewer on the left, all of them show their names.
- **Dictation:** `Sources/Dictation.swift` (key, audio, text) and `Sources/Parakeet.swift` (models, download,
  recognition). A listen-only event tap watches one modifier key while dictation is on (Accessibility); held 0.25 s
  without another key → recording (AVAudioEngine, resampled to 16 kHz mono); an active tap swallows Return (finish)
  and Escape (cancel) only while recording. Recognition on a serial queue: Parakeet TDT 0.6B v3 in Core ML
  (Preprocessor → Encoder → Decoder/JointDecisionv3, greedy TDT, 15 s windows cut at the quietest moment, decoder
  state carried over). Text goes in by clipboard + ⌘V, marked `org.nspasteboard.TransientType`, and the previous
  clipboard comes back 0.6 s later; Accessibility reads 3 characters before the cursor for case and spacing.
  Models: `~/Library/Application Support/Nook/Models/parakeet-{ultra,redux}`, every file pinned by revision, size
  and SHA-256 (`ParakeetFile`); downloads go to `*.partial` and are renamed only when complete. To try the engine
  without the app, compile `Sources/Parakeet.swift` with a small `main.swift` (it needs `supportDir`) and feed it
  `say -o x.aiff` speech. Ultra: 7 s of speech in ~0.1 s on M-series, first load ~10 s (Core ML compiles for the
  Neural Engine), then ~0.2 s. Redux needs macOS 15 and loads slower (~12 s).
