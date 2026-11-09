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

The DMG window (a lime tile like the icon, an arrow from Nook to Applications) comes from `dmg/background.tiff`
and `dmg/DS_Store`, which `release.sh` copies into the image (volume "Nook", HFS+: the layout finds the picture by
volume name and path). `dmg/make-assets.sh` redraws the picture and has Finder record the layout on a scratch image
(the first run asks for permission to control Finder); commit both files afterwards. Without them `release.sh` warns
and the image opens as a plain Finder window. Finder keeps black icon names on a window with a picture,
in Dark Mode too, so the picture stays light.

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

`Nook --show home|clipboard|shelf|ai|notes|mirror|calendar|timer|cuely|power|limits|close` opens a tab of the running
app (`power` opens Home with the battery card, `limits` the Agents tab with the limits details); `Nook --show settings[:pane]` opens the Settings window
(panes: general, panel, launcher, snippets, clipboard, ai, notch, notifications, dictation, agents, privacy, updates,
thanks).
`Nook --show launcher` opens the search with the keyboard in it; `Nook --show launcher:<text>` shows the results for
`<text>` without taking the keyboard (for checks: typing keeps going to the app in front).
`Nook --dictate [start|stop|cancel|toggle]` drives dictation; it is refused from processes an agent started
(they would hear the person and get the text typed into their own terminal), like `--answer`.
`Nook --timer 25|stop|pomodoro` and `Nook --prompt` (start Cuely) for Raycast / Shortcuts.
`Nook --answer allow|always|deny|terminal` answers the oldest pending agent request. It works from your own
terminal, not from a process an agent started (an agent must not approve its own request).
The check (`AgentHub.runsUnderAgent`) walks up the caller's parents: claude, codex or node on the way refuses it, and
so does reaching launchd without passing an app (Terminal, iTerm, Raycast) or a process under `/System` (Shortcuts).
That stops an agent's `( … & )` or nohup, whose process launchd adopts. It also refuses terminals hosted by a
background server (Orca's terminal host, herdr, tmux): use Terminal, Raycast or Shortcuts for `--answer` and `--dictate`.
Timer values are checked: more than 0 and at most 24 h.

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
  `Stop` keeps the whole answer (`Session.reply`, markdown, ≤ 12 000 characters, in `sessions.json`) and the turn's
  length (`took`). The Agents feed draws it first, in `ReplyCard` (`Sources/AgentReply.swift`): a line-based markdown
  reader (headings, lists, code, tables, quotes; inline marks by `AttributedString`), folded to 4 lines (3 when
  several turns are done) and unfolded by a click; a last paragraph ending in «?» is pulled out under the answer with
  the yellow edge. Test it with a fake session: `UserPromptSubmit` then `Stop` with `last_assistant_message`.
- **Sleep in games** (`Sources/GameWatch.swift`): when the app in front fills the notch's display, Nook hides the
  notch (`NotchModel.hidden`, opacity 0, loops paused), stops hover polling and holds drops back until it leaves;
  hotkeys and `--show` still open the panel, the volume and brightness keys still flash. Settings → General →
  Засыпать: «В играх» (default; `LSApplicationCategoryType` `public.app-category.*games` as Game Mode needs, or a
  known cloud app such as GeForce NOW `com.nvidia.gfnpc.mall`; a window from under the menu bar down counts), «В
  любой программе на весь экран» (a window over the whole display, or `AXFullScreen` on the focused window: a native
  full-screen window on a notch display starts below the menu bar, whose window stays listed as the black band beside
  the notch), «Никогда». Checked on app switches, Space and display changes, again
  1.5 s later; every 3 s only while a game is in front. Window lists and Info.plist are read on its own queue.
- **Updates:** `Sources/Updater.swift` reads the latest GitHub release, downloads `Nook.zip`, accepts it only if
  it is signed by Nook (`signedByNook`: the running app's designated requirement or Nook's Developer ID), and then
  offers it: a drop «Вышла Nook 1.N» (Позже / Установить), again on every later check, plus Settings → Updates
  and the status menu. It installs only when asked (a restart drops coffee mode, timers and dictation).
- **Volume:** `Sources/Volume.swift` watches the default output device (CoreAudio). With Accessibility access it
  also takes the volume keys (event tap on NX_SYSDEFINED), sets the level itself in 1/16 steps (⌥⇧: 1/64), so the
  macOS HUD does not appear. Without access the keys stay with macOS and Nook only shows the change.
- **Brightness:** built-in display via DisplayServices (private). Shown only after a brightness key, never for
  automatic brightness. **Focus / Do Not Disturb:** `Sources/Focus.swift` watches `~/Library/DoNotDisturb/DB`
  (needs Full Disk Access) with file-system events, no polling; `focus-debug.log` records structure only.
- **Pointer:** event-driven polling; the panel takes the keyboard only for text fields. While any menu is open
  (another app's: HIToolbox's distributed begin/end menu tracking notifications; Nook's own: `NSMenu` ones),
  hovering does not open the panel and an open panel does not close: the status menu drops right beside the notch.
- **Keys:** an accessory app has no menu bar, so `installEditMenu()` adds an invisible Edit menu for ⌘A/⌘C/⌘V/⌘X/⌘Z in
  fields (no Close or Quit: they would close the notch). The panel takes ⌘1 (Search ⇄ Clipboard) and ⌘C (copy the
  chosen clipboard entry when no text is selected) in `NotchModel.performKeyEquivalent`; Settings takes ⌘W and ⌘Q.
  All match the key code: with a Cyrillic layout the characters are «ц», «й», «с».
- **Clipboard:** `Sources/ClipboardList.swift`. Type to filter, ↑↓ choose, ↩ pastes into the app the panel was
  opened from (copies without Accessibility), ⌘C copies, double click pastes; the chosen entry shows in full with
  its source, type, size and time. From the search, ⌘1 opens it over the search and Esc or ⌘1 goes back. Opened by
  hover the panel has no keyboard; a click on an entry gives it the keyboard (`takeKeyboard`), so the arrows work.
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
- **Menu items and open windows** (`Sources/LauncherAX.swift`): read once per opening of the search on their own
  queue — the front app's menu bar (≤ 4000 items, 1 s, enabled leaves only; never opens a menu) and every regular
  app's standard windows (0.2 s per app). Menu items join the results from two typed letters; ↩ presses the item
  after the app is back in front, a window is raised (and unminimized).
- **AI** (`Sources/Assistant.swift`): one streamed request at a time. Claude Code route: `claude -p --setting-sources
  project --no-session-persistence --tools "" --output-format stream-json --include-partial-messages` from the data
  folder — no user settings means no hooks, so the call never appears as an agent session; the prompt goes in on
  stdin (arguments are visible to other processes). API route: Messages API with SSE, `anthropic-version: 2026-10-21`,
  `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`), key in the keychain (service `dev.nook.app.ai`).
  Apple route: FoundationModels on macOS 26. Selection: AX `kAXSelectedText`, else a borrowed ⌘C with the clipboard
  restored. Quick actions run at `effort: low`; a summary opens in the search, the others replace the selection.
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
  without another key → recording; an active tap swallows Return (finish) and Escape (cancel) only while recording.
  The microphone is an Audio Queue that records 16 kHz mono Float32 itself (`AudioInput`), opened and closed on
  `audioQueue`, never on the main thread: Core Audio can hang while it asks the hardware (AVAudioEngine's
  `inputNode` once froze the whole notch there). A watchdog gives up after 3 s: "The microphone isn't responding",
  and dictation stays off until the queue answers. Other sound fades down to 5 % in 0.3 s (`VolumeControl.duck`,
  60 steps a second, eased at both ends) from the moment the hold key goes down (a combination, a double tap or
  `--dictate`: from the start of recording), so the start sound plays at the lowered level. A tap or ⌥+letter fades
  it back; after recording it fades back in 0.4 s on the same device, at once on quit, never over a level the person
  set meanwhile.
  `~/Library/Application Support/Nook/dictation-debug.log` keeps the last ~200 lines: how long the microphone took to
  open, length, recognition time, characters, pasted or copied (never the text). Recognition on a serial queue: Parakeet TDT 0.6B v3 in Core ML
  (Preprocessor → Encoder → Decoder/JointDecisionv3, greedy TDT, 15 s windows cut at the quietest moment, decoder
  state carried over). Text goes in by clipboard + ⌘V, marked `org.nspasteboard.TransientType`, and the previous
  clipboard comes back 0.6 s later; Accessibility reads 3 characters before the cursor for case and spacing.
  Models: `~/Library/Application Support/Nook/Models/parakeet-{ultra,redux}`, every file pinned by revision, size
  and SHA-256 (`ParakeetFile`); downloads go to `*.partial` and are renamed only when complete. To try the engine
  without the app, compile `Sources/Parakeet.swift` with a small `main.swift` (it needs `supportDir`) and feed it
  `say -o x.aiff` speech. Ultra: 7 s of speech in ~0.1 s on M-series, first load ~10 s (Core ML compiles for the
  Neural Engine), then ~0.2 s. Redux needs macOS 15 and loads slower (~12 s).
- **Streaming dictation engine (not in the UI yet):** `Sources/Nemotron.swift`, NVIDIA Nemotron 3.5 ASR Streaming 0.6B
  in FluidInference's Core ML build (`multilingual/1120ms`, 615 MB, pinned like Parakeet; installed to
  `Models/nemotron-3.5-1120ms` by `ModelDownload(manifest: NemotronModel.manifest)`). `NemotronStream`: `begin(language:)`
  ("auto", "ru", "uk", "en", …), `feed` from any thread, `onPartial` every 1.12 s of audio (the text only grows),
  `finish` decodes the tail plus one chunk of silence (without it the closing full stop is often missing).
  Mel features in Swift as one stream (Accelerate), encoder caches carried between chunks, greedy RNN-T. M4 Pro:
  first load in a new executable ~10 s, then ~0.15 s; 15 ms per chunk when busy, ~50 ms in real time (the Neural
  Engine wakes up per chunk); ~65 MB footprint. Try it with a scratch CLI that compiles `Parakeet.swift`,
  `Nemotron.swift` and stubs for `supportDir` and `L`, as for Parakeet. Core ML outputs are autoreleased: decoding many
  chunks in one work item needs a pool per chunk (it once reached 391 MB on 3 minutes of audio).

## Localization

- Russian is the source text and the key. English, German and Ukrainian live in
  `Sources/Localization/{en,de,uk}.lproj/Localizable.strings`; `ru.lproj` stays empty so macOS counts Russian as one
  of Nook's languages. `install.sh` copies every `.lproj` into the app; `Info.plist` lists them in
  `CFBundleLocalizations`. Permission prompts: Russian in `Info.plist`, the others in `<lang>.lproj/InfoPlist.strings`;
  a new usage string needs all four.
- Literal titles (`Text("…")`, `Button("…")`, `Toggle`, `Picker`, `Section`, `LabeledContent`, `.help`) are looked
  up by SwiftUI. Text built in code goes through `L("…")` (`Sources/Localization.swift`). Text glued with `+`
  inside `Text(…)` is a plain String and is not looked up: wrap the Russian part in `L(…)`.
- Interpolations become `%@` (String), `%lld` (Int), `%d` (Int32), `%lf` (Double) in the key; with any
  interpolation a literal `%` becomes `%%`. Plurals: `Format.count(n, one, few, many)`; English and German use `one`
  and `many`, Ukrainian all three like Russian (each word is its own entry).
- Words the calculator reads in the input, search keywords, AI prompts and logs are not translated.
- After adding text: `python3 Sources/Localization/check.py` lists Russian text without English, and German or
  Ukrainian entries that are missing, extra or with other placeholders (exit status 1). New text needs all three.
- A view with both a `LocalizedStringKey` and a `StringProtocol` init must mark the second `@_disfavoredOverload`
  (as SwiftUI's `Text` does), or string literals pick it and stay Russian (it happened to `SettingsRow`).
- Settings → General → Language writes `AppleLanguages` and a matching `AppleLocale` (`en_UA`: English words, the
  region's formats) into Nook's defaults; a new language needs a restart. Try English without the menu:
  `defaults write dev.nook.app AppleLanguages -array en`, restart; `-bool YES` for `NSShowNonLocalizedStrings`
  shows text without a translation in capitals. Delete both keys afterwards.

### AirPods switching

macOS gives no API for "your AirPods moved to another device", and its own banner cannot be turned off
(`com.apple.BTUserNotifications`, posted by `audioaccessoryd`, has `UNHideSettings`). Nook reads the banner's log line
through a `/usr/bin/log stream` child (`HeadphoneBanners` in `Sources/Devices.swift`): «PostingBanner: Type
ReverseRoute …» plus the metrics line that names the other device. The text is not an API: check it after macOS
updates with `log stream --predicate 'process == "audioaccessoryd" AND eventMessage BEGINSWITH "PostingBanner: Type "'`.
«Вернуть на Mac» opens the connection if it dropped, then plays 3 s of silence on the AirPods output so macOS routes
them back; a phone playing media (higher priority) can refuse.
