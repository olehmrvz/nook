# Nook

Own notch app for macOS that replaces Notchy. Native Swift/SwiftUI, no analytics, no account, no network
calls except weather (Open-Meteo), the update check (GitHub releases of this repository) and, in the
AppleScript fallback, Spotify cover art.

## Install (Apple Silicon, macOS 14+)

1. Download `Nook.zip` from the latest release: https://github.com/olehmrvz/nook/releases/latest
2. Unpack it and move `Nook.app` to «Программы» (Applications), then open it.
3. macOS says it cannot check the developer (the app is not notarized by Apple): System Settings →
   Privacy & Security → "Open Anyway". If it says the app is damaged:
   `xattr -dr com.apple.quarantine /Applications/Nook.app`, then open it again.

Claude Code and Codex connect by themselves on first launch: Nook adds its hook to `~/.claude/settings.json`
and `~/.codex/hooks.json` (and turns on hooks in `~/.codex/config.toml`), keeping a `.bak-nook` copy of each.
Codex may ask once to trust Nook's hooks.

Check that your copy is genuine: `codesign -dvv /Applications/Nook.app` must show `Authority=Nook Local Signing`,
and `codesign -d -r- /Applications/Nook.app` must end with `certificate leaf = H"76a699582536149bb53212178f4a1b2a2dc15cc1"`.
Each release lists the SHA-256 of `Nook.zip`. Updates are accepted only with this same certificate.
Agents already running need a restart. Updates install by themselves (menu ⚙︎ → Обновления).

Look: "Сияние" — black notch, glass cards over a soft glow tinted by what happens now (the cover of the
playing track, Claude waiting, an island's own colours). The band under the camera always stays pure black.

- **Notch:** hover the camera notch to open the panel. While music plays or an agent works, small live
  indicators sit left and right of the notch.
- **Home:** player for whatever plays on the Mac (any app: Spotify, Music, a browser tab, podcasts), agents with
  your request, current action, branch, turn time and edited files, Claude limits, next event, weather.
- **Now Playing** comes from the system (MediaRemote) through `Sources/MediaRemote`: a small dylib loaded into
  Apple's `/usr/bin/perl`, because macOS 15.4+ answers MediaRemote only to Apple-signed processes. If the
  bridge fails, AppleScript covers Spotify and Music.
- **Clipboard (⌃⌘V):** history of 300 items plus pins, search, arrow keys and ↩. Items from password managers
  (concealed / transient types) are never saved. With Accessibility access, ↩ pastes into the previous app.
  Right-click an image → copy its text (on-device OCR, Vision). Deleting or clearing can be undone for 15 s;
  a sudden drop of the history keeps `clipboard.json.bak`.
- **Shelf:** drop files on the notch, drag them out, AirDrop, Quick Look thumbnails. New screenshots and
  screen recordings land here automatically. Right-click: copy the file, copy text from an image.
- **Agents:** Claude Code and Codex sessions (working / waiting / done) through hooks. Permission requests
  appear in the notch: Allow, Always (applies Claude's suggested rule), Deny, or "in terminal". Unanswered
  requests fall back to the terminal after 110 s. Claude 5 h / week and Codex limits come from local files.
  Sessions survive a Nook restart (`sessions.json`); click a session (or a "готово" island) to bring back its
  exact herdr tab or tmux pane and the terminal app (read once from the agent's environment).
  States read at a glance: white moving dots + "Работает", green ✓ + "Готово", still amber dot + "Ждёт…".
  Claude's questions (AskUserQuestion) and plans (ExitPlanMode) can be answered in the notch: pick options or
  type your own answer; approve a plan, approve with auto-accepted edits, or send it back with a note.
  "В терминале" always leaves the decision to the terminal dialog.
- **Long commands (zsh):** menu → "Острова для долгих команд (zsh)…" adds one line to `~/.zshrc` (with a backup).
  A command that ran 20 s or longer (`NOOK_MIN_SECONDS`) shows an island with its result, unless you are looking
  at that terminal tab. Interactive programs (vim, ssh, less, top, claude…) are skipped.
- **Notes:** plain-text notes, saved while you type. **Mirror:** the built-in camera, on only while the tab is open.
- **Battery:** charge level, a flash when the charger is connected; click the header chip for details (health,
  cycles, time left) and the way to the macOS charge limit (80–100 %, macOS 26.4+). Nook never writes to the
  battery controller itself.
- **Islands:** short pills that drop out of the notch: agent finished (project, last message, time; click →
  its terminal), app notifications and messages, incoming calls (caller photo from Contacts), AirPods /
  headphones with battery levels, finished downloads (open / put on shelf), timer done, meeting in 5 min
  (join button). Hover keeps an island open; right-click a notification to mute that app.
- **Calendar:** today's and tomorrow's events with meeting links, open reminders (tick off, add new).
- **Timer:** presets and Pomodoro 25/5 (long 15 break after four); countdown lives in the collapsed notch.
- **Cuely:** teleprompter right under the camera; fixed pace or voice follow (on-device speech, ru/de/en/uk).
- **Weather:** Open-Meteo by location (falls back to the time-zone city); in the header and on Home.
- **Live activities** in the collapsed notch, by priority: permission request, timer, download progress,
  agent working, music (cover on the left while an agent works on the right).
- **Keys:** ⌘1–⌘9 switch tabs and Esc closes the panel while it has focus. The menu can hide Nook from
  screenshots and screen sharing.

## Build and install

`./install.sh` builds with the Swift compiler from Command Line Tools, installs `~/Applications/Nook.app`
(signed with "Nook Local Signing" from `make-cert.sh`, ad-hoc without it) and starts it. The version is the
number of commits (`1.<count>`). `./release.sh` publishes the current commit as a GitHub release; every
installed Nook picks it up within 6 hours, checks that it is signed with the same certificate, and installs it
when the panel is closed. Menu bar icon → "Запускать при входе" adds a LaunchAgent
`~/Library/LaunchAgents/dev.nook.app.plist`.

Hooks: connected automatically on first launch for each agent found (`~/.claude`, `~/.codex`), once — hooks
removed later are not put back. By hand: menu → Агенты → "Подключить", or `Nook --install-hooks`. For Codex,
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
  back). Экран: pick the display for the notch (on a display without a notch it is a small pill).
- ☕ in the header: "coffee" keeps the Mac awake while idle (agents left working). The display still sleeps.
- `notifications-debug.log` in the data folder records bundle ids and key names (never message text) of the
  first 40 notifications, to check the database format on new macOS versions.
