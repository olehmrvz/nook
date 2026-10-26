# Nook

Own notch app for macOS that replaces Notchy. Native Swift/SwiftUI, no analytics, no account, no network
calls except Spotify cover art.

- **Notch:** hover the camera notch to open the panel. While music plays or an agent works, small live
  indicators sit left and right of the notch.
- **Home:** Spotify / Music player (cover, seek, controls), agent summary, shelf and clipboard.
- **Clipboard (⌃⌘V):** history of 300 items plus pins, search, arrow keys and ↩. Items from password managers
  (concealed / transient types) are never saved. With Accessibility access, ↩ pastes into the previous app.
- **Shelf:** drop files on the notch, drag them out, AirDrop, Quick Look thumbnails. New screenshots and
  screen recordings land here automatically.
- **Agents:** Claude Code and Codex sessions (working / waiting / done) through hooks. Permission requests
  appear in the notch: Allow, Always (applies Claude's suggested rule), Deny, or "in terminal". Unanswered
  requests fall back to the terminal after 110 s. Claude 5 h / week and Codex limits come from local files.
- **Battery:** charge level; a short flash when the charger is connected.
- **Islands:** short pills that drop out of the notch: agent finished (project, last message, time; click →
  its terminal), app notifications and messages, incoming calls (caller photo from Contacts), AirPods /
  headphones with battery levels, finished downloads (open / put on shelf), timer done, meeting in 5 min
  (join button). Hover keeps an island open; right-click a notification to mute that app.
- **Calendar:** today's and tomorrow's events with meeting links, open reminders (tick off, add new).
- **Timer:** presets and Pomodoro 25/5 (long 15 break after four); countdown lives in the collapsed notch.
- **Cuely:** teleprompter right under the camera; fixed pace or voice follow (on-device speech, ru/de/en/uk).
- **Weather:** Open-Meteo by location (falls back to the time-zone city); in the header and on Home.
- **Live activities** in the collapsed notch, by priority: permission request, timer, download progress,
  agent working, music.

## Build and install

`./install.sh` builds with the Swift compiler from Command Line Tools, installs `~/Applications/Nook.app`
(ad-hoc signed) and starts it. Menu bar icon → "Запускать при входе" adds a LaunchAgent
`~/Library/LaunchAgents/dev.nook.app.plist`.

Hooks: menu bar icon → "Подключить Claude Code и Codex", or `Nook --install-hooks`. This adds Nook's hook to
`~/.claude/settings.json` and `~/.codex/hooks.json`, removes Notchy's hooks, keeps all other hooks and saves
a `*.bak-nook-<time>` copy first.

## Permissions

Notifications and calls read the Notification Center database and need **Full Disk Access** for Nook.
Calendar, Contacts, Bluetooth, Location, Microphone/Speech are asked when first used.
Run `./make-cert.sh` once (asks for your password to trust the certificate): `install.sh` then signs with the
stable "Nook Local Signing" identity, so macOS keeps these grants across rebuilds. Without it each rebuild
is ad-hoc signed and macOS may ask again.

## Command line

`Nook --show home|clipboard|shelf|ai|calendar|timer|cuely|close` opens a tab of the running app.
`Nook --timer 25|stop|pomodoro` and `Nook --prompt` (start Cuely) for Raycast / Shortcuts.
`Nook --answer allow|always|deny|terminal` answers the oldest pending agent request.

## Notes

- Data: `~/Library/Application Support/Nook` (clipboard.json is mode 600).
- `notifications-debug.log` in the data folder records bundle ids and key names (never message text) of the
  first 40 notifications, to check the database format on new macOS versions.
