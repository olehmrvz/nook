# Nook — own replacement for Notchy

## Objective
Replace the now-paid Notchy (v2.0.0, `/Applications/Notchy.app`, bundle `dev.notchy.app`) with an own
notch app, then remove Notchy and its integrations.

## Discoveries (2026-10-26)
- Notchy: 229 MB binary, 26 tabs, Sparkle updates, Google Analytics IDs in Info.plist, trial started 2026-10-26.
- Real usage from its defaults: clipboard 898 actions, shelf 42, timers 1; tabs on: AI usage, Cuely, files,
  mirror, notes, terminal. Last music app Spotify. Screenshots from Desktop auto-land on the shelf.
- Integrations to remove: hooks in `~/.claude/settings.json` and `~/.codex/hooks.json` that call
  `~/Library/Application Support/Notchy/agent-hook.sh` (unix socket `agent-hook.sock`, token file).
- Its clipboard pins file is encrypted (`NTCHSEAL`), so it cannot be migrated.
- Claude limits: `~/.config/panegrip/claude-limits.json` and `cachedUsageUtilization` in `~/.claude.json`
  (same sources as `t3-claude-limits-menubar`). Codex limits: `rate_limits` in newest `~/.codex/sessions` jsonl.
- Toolchain: Command Line Tools only (Swift 6.2, no Xcode) → build with `swiftc`, like t3-claude-limits-menubar.

## Scope v1 (Nook)
Notch pill + hover panel; Now Playing (Spotify/Music via AppleScript); clipboard history with pins, search,
global hotkey ⌃⌘V, skip of password-manager items; file shelf (drop, drag out, AirDrop, new screenshots);
AI agents (Claude/Codex sessions via hooks, approve/deny permission requests from the notch, Claude 5h/7d and
Codex limits); battery/charging flash; launch at login (LaunchAgent).

## Steps
- [x] Write sources + install.sh (repo root), installed to `~/Applications/Nook.app`
- [x] Visual check of home / clipboard / shelf / agents tabs and collapsed flash (screencapture)
- [x] Verified: clipboard capture (pbcopy → clipboard.json), screenshot → shelf, hook delivery,
      PermissionRequest answers allow / always (updatedPermissions) / deny / terminal (empty output)
- [x] Notchy.app, prefs (exported), support data moved to `~/.Trash/Notchy-removed-2026-10-26`
- [x] Hooks switched by the user 2026-10-26 12:48Z (backups `*.bak-nook-2026-10-26T12-48-08Z`); live Claude sessions show in Agents tab
- [ ] USER: menu → "Запускать при входе" — LaunchAgent creation blocked for the agent
- [x] Notchy hook leftover moved to Trash; real sessions verified (PID lookup keeps them listed)
- [ ] Leftover TCC-protected dirs (delete in Finder): `~/Library/Containers/dev.notchy.app.widget`,
      `~/Library/Group Containers/PKQWZ2BV83.dev.notchy.app`

## Open issues
- Codex PermissionRequest output assumed to use the same JSON as Claude Code (Notchy did the same); unverified.

## Phase 2 (requested 2026-10-26)
Calendar + reminders tab, timer/pomodoro tab, Cuely teleprompter (auto + voice follow), AirPods island,
calls + notification islands (usernoted DB, needs Full Disk Access), downloads island (NSProgress
file subscriptions + Downloads scan), weather (Open-Meteo + CoreLocation), rich "agent done" island
(last_assistant_message, duration, click → terminal). Islands = queued medium pills under the notch;
panel ignoresMouseEvents is driven by pointer position. Stable signing to keep TCC grants across rebuilds.

### Phase 2 status (2026-10-26)
- [x] Built and installed; tabs Home/Calendar/Timer/Cuely captured; weather resolved Garbsen via Location.
- [x] Verified live: agent-done island (Stop hook with last_assistant_message), timer countdown in notch,
      timer-done island, download island (curl into ~/Downloads), prompter auto-scroll.
- [x] Folder reads and AppleScript moved off the main thread (a TCC prompt froze the UI before).
- [ ] Unverified until permissions/devices: notifications + calls (needs Full Disk Access; check
      notifications-debug.log), AirPods island (connect event), calendar data, Cuely voice follow.
- [ ] USER: `make-cert.sh` (keychain import + trust blocked for the agent), then rebuild, then grant
      permissions once; menu → "Запускать при входе".
- [x] Open/close animation fixed: clip on the persistent container (inserted content drew outside the
      growing shape), one spring keyed on mode (no bounce on close), no orderOut/orderFront blink.
      Checked with `defaults write dev.nook.app slowMotion -float 10` frame captures.
- [x] Stable signing identity "Nook Local Signing" created by the user; install.sh falls back to ad-hoc.

## Workspace (2026-10-26)
- Repo: github.com/olehmrvz/nook (private). Local clone: `~/Developer/agents/Nook`, branches `main` (stable) and
  `develop` (work). The old copy in the Sandbox worktree `choose/nook/` (commit d3f1e3a) is superseded.
- Next concrete action: after the user grants Full Disk Access, read `notifications-debug.log` and confirm the
  notification DB format; then verify calendar data, AirPods island and Cuely voice follow.

## Design refresh (requested 2026-10-26)
Goal: a nicer-looking expanded panel. Decide on paper first, then build in SwiftUI.
- [x] Figma "Sandbox" → page "Nook": https://www.figma.com/design/TKW5XTlfIPhx9RdAb4TVoA
  Four directions, each with Home, Agents (permission request), collapsed notch and island on a desktop backdrop:
  A «Остров» (black, no grey cards, one accent), B «Сияние» (glass over glow taken from artwork / agent state),
  C «Бенто» (coloured widget tiles, activity rings), D «Терминал» (mono, key hints, lime accent).
- Mockups use Inter / Nunito / Geist Mono: SF Pro is a local font and breaks text created through the Figma MCP.
  Icons are SVG stand-ins for SF Symbols. Other sessions share this Figma file (page "Panegrip — …").
- [x] USER picked B «Сияние» as is (2026-10-26).

### Implementing B «Сияние»
- `Sources/Theme.swift` (new): palette, glass card, pill buttons, glow bar, ring gauge, ambient glow,
  artwork colour extraction. Glows are elliptical gradients (cheap), not blurred layers.
- Glow colours: Home ← artwork (`NowPlaying.glow`, fallback pink/violet) + coral when Claude waits;
  Agents ← coral; other tabs have fixed pairs; islands ← their kind; collapsed music ← underglow.
- Header: two glass capsules around the camera with a sliding active pill (matchedGeometryEffect),
  weather + battery in one chip (right side is only ~273 pt wide).
- [x] Theme.swift, all tabs restyled, motion (materialize, staggered cards, sliding pills, numeric text,
  ring fill, symbol replace); built and installed, Home / Clipboard / Shelf / Timer / Cuely captured 2026-10-26.
- [x] Captured live 2026-10-27: Home with music (Spotify, then a Chrome video), Agents with sessions, collapsed
  (cover + agent spinner), agent-done island, Notes, power card. Not captured: Calendar no-access, slow motion.
- [x] User request: the band under the camera stays pure black; glow rises from below (`AmbientGlow(blackTop:)`);
  islands have colour pairs per kind, app notifications take their icon's colours.

### Functional pass (requested 2026-10-27)
- [x] Agent sessions persist in `sessions.json` (mode 600, tolerant decoding) and come back after a restart
  (only live agent PIDs; waiting → attention). Verified: sessions with no new hooks reappeared after reinstall.
- [x] Clipboard image previews load off the main thread (ImageIO thumbnails); row context menu, full-text tooltip,
  "включить вставку" button when Accessibility is missing; OCR "copy text from image" (Vision) for clipboard
  images and shelf images.
- [x] Shelf save / existence checks moved off the main thread; "Скопировать" in the tile menu.
- [x] ⌘1–⌘9 tabs, Esc closes the panel, weather card opens Weather, "Подключить" hooks button in Agents,
  menu toggle "Скрывать Nook при показе экрана" (`sharingType = .none`).
- [x] Universal Now Playing: ObjC bridge dylib (`Sources/MediaRemote/`) loaded by `/usr/bin/perl`, JSON lines
  on stdout, commands on stdin, exits on stdin EOF; AppleScript stays as fallback. Verified reading Spotify and
  a Chrome video with artwork. Commands (toggle / next / previous / seek) NOT exercised: they would change
  the user's playback — ask the user to try.
- [x] Richer agents: prompt, current action (tool + target), turn time, git branch (skips TCC-guarded
  folders), edited files, last message, Notification text; Home = compact player | agents | event + weather,
  limit mini-rings on Home. Agents tab shows the roomy version.
- [x] Notchy parity: Notes tab (`notes.json`), Mirror tab (camera only while open; NSCameraUsageDescription).
  A camera prompt was triggered once by mistake during checks — the user has to answer it.
- [x] Battery: power card under the header chip (`--show power`): %, held / charging / time left, health 96 %,
  138 cycles, low-power state, button to the macOS charge limit. Research: macOS 26.4+ has a native
  80–100 % limit; SMC writes are gated on this firmware (batt #152) — Nook does not write SMC.
  This Mac already holds at 80 % (plugged, not charging, NotChargingReason ≠ 0).
- Research summary (subagent, 2026-10-27, sources in the conversation): notchy.dev features, boring.notch,
  Atoll, Alcove, DynamicLake, NotchDrop, MediaMate, agent-island apps (Vibe Island, Claude Island…).

### Backlog (ranked, not started)
1. AskUserQuestion answers and ExitPlanMode plan review in the notch (hook mechanics unverified).
2. Jump to the exact terminal tab / pane (Ghostty, herdr, tmux) instead of only the app.
3. Long-running shell command islands (zsh preexec/precmd; needs a ~/.zshrc line from the user).
4. Synced lyrics for the player (LRCLIB, network call — opt-in).
5. Camera / mic in-use indicator, global mic mute.
6. Listening ports / dev servers, system stats.
7. Shelf actions: zip, image convert, merge PDFs.
8. Terminal tab (needs a vendored terminal emulator; swiftc-only build).
9. Multi-display: follow the active display.

Next concrete action: ask the user to try play/pause/next/seek from Nook, answer the camera prompt,
then pick items from the backlog. Changes are uncommitted on `develop`.

### Session 2026-10-27 (late) — stopped at usage limit
- [x] Fixed: list first rows clipped (4 pt top inset in `ListScroll`), header pushed up (fixed tab height
  `contentHeight`, panel 326 pt tall), calm indicators (white dots = working, still amber dot = needs you,
  green ✓ = done; "waiting for your input" now counts as done), soft island backgrounds and glass badges,
  limits card with reset times and even-pace marks.
- [x] Ideas 1–3: AskUserQuestion / ExitPlanMode cards (answers via `updatedInput.answers`, plan approve /
  acceptEdits / deny with note) — rendering verified with fake requests, real answer path NOT yet verified;
  herdr / tmux jump (env via KERN_PROCARGS2) — terminal data verified, focus not executed; zsh long-command
  islands — verified in a clean `zsh -f -i`, the user still has to click the menu item to add it to ~/.zshrc.
- [x] Keyboard safety: `becomesKeyOnlyIfNeeded`, search focus only when key, destructive buttons not focusable;
  clipboard undo (15 s), `.bak` on sudden drop, unreadable file set aside.
- Clipboard history was found reduced to 2 items at 00:36 (cause unconfirmed; suspected keystrokes reaching the
  panel). No Time Machine snapshot to restore from.
- [x] Security and performance reviews rerun (2026-10-27, two independent reviewers) and acted on.

### Hardening pass (2026-10-27, night)
- [x] Security: CLI commands and `--answer` go over the owner-only socket with the token (the
  `dev.nook.answer` broadcast is gone); hardened runtime + `Nook.entitlements`; request buttons armed after
  0.7 s; plan links https only; herdr / tmux paths fixed (no binary from the agent's env); meeting links
  strict hosts; weather coordinates rounded; socket 32 slots and 10 s read deadline.
- [x] Energy: pointer polling only near the notch or while something is shown (global mouse-moved monitor
  starts it); idle auto-close after 2 min (not while an unanswered request is shown); panel closes and
  loops pause while screens sleep / are locked (also detected at launch); notification DB polled off the main
  thread, a refused open retried once a minute; spinners 12 fps; Now Playing bridge polls every 10 s and only
  real changes are assigned; Downloads, Battery, Calendar (5 min, off main), Codex limits (cached, YYYY/MM/DD
  walk), timer (no redraw every 0.5 s), Cuely (debounced save) assign / write only on change.
  Measured with the screen locked: 3.3–3.7 % CPU and ~52 wakeups/s before → 0.1–0.2 % and 0–1 after.
- [x] Clipboard data: save after a failed load is disabled; hourly `.bak` plus one before an unexplained drop
  below half of this session's peak; deleted entries are scrubbed from `.bak` too; clear removes it; image
  PNG encode and all writes off main; text over 1 MB not stored; `clipboard-events.log` (counts and sources
  only) to trace the next loss. Verified by a scratch harness compiled from `Clipboard.swift` (all pass).
- [x] Single instance (a second launch or an unknown `--flag` exits); `install.sh` waits for the old process.
- [x] Session auto-cleanup: done / idle sessions leave the list after 10 min.
- [x] After unlock: Home / Agents / Clipboard screenshots fine; the paused loops restart after unlock.
  Found ~4.5 % CPU and ~120 wakeups/s with agents working: `sample` showed every TimelineView frame of the
  dots re-laying out the whole window. Dots and music bars moved to Core Animation (`LayerLoop`);
  the screen locked again before this could be measured unlocked.
- [ ] Not verified (screen locked all night): hover-to-open with the event-driven polling, file drag to the
  shelf, idle auto-close, re-open on wake with a pending request, visuals of the request cards.
- [ ] Remaining low-priority review items: DispatchSource instead of 2 s Desktop/Downloads scans; Downloads
  `@Sendable` capture warning; follow the active display.

Next concrete action: after the user unlocks, check hover-open, drag to shelf and Home/Agents screenshots;
then commit on `develop` when the user asks.

## Updates, menu, displays, coffee (2026-10-27, evening)

Done and checked:
- Shadow: window 900×400, so the panel shadow fades inside it (was cut into a band at 356 pt).
- Idle auto-close counts from the moment the panel opened (a panel opened by a script closed at once).
- Agents connect on first launch, once per agent; Codex also gets `[features] hooks = true`
  (config edit tested on 6 sample files: none, other keys, hooks=false, hooks=true, dotted keys, empty).
- Menu regrouped (Экран, Агенты, Уведомления, Доступ и приватность, Обновления), also under ⚙︎ in the panel;
  the menu bar icon can be hidden, opening Nook.app again brings it back.
- Display choice: checked by moving Nook to the external MAG274Q and back.
- Coffee button (IOPMAssertion PreventUserIdleSystemSleep).
- Repo made public; `release.sh` published v6. Updater checked end to end: build 1.3 updated itself to 1.6
  in ~75 s (download, signature check, replace, restart).

Not checked: the menu itself (needs a click), the coffee button click, hiding the icon, and a first launch
on a Mac without Nook (the brother's).

## Security pass (2026-10-27, late)

Three independent reviews (agents/IPC, updates/build, data/privacy); findings checked against the code, fixed in
f30a460. Verified: masking rules on 7 sample commands; .git reads refuse a /dev/zero link and a FIFO; TOML edit
with comment/space headers, arrays, duplicate tables; a changed bridge dylib fails the seal check; a permission
card shows hidden fields; `Nook --answer allow` from under an agent is ignored; data folder is 0700.
Not released yet (v6 is the latest release). Open, by design or for later: the signing key on the dev Mac is the
single root of trust for updates (no offline key, no Developer ID); `hideFromCapture` stays off by default.

## Developer ID and notarization (2026-11-06, branch `olehmrvz/certificate`)

Goal: downloads open without Gatekeeper warnings, updates keep working, permissions survive rebuilds.
Found: paid Individual team `T2KMY2TV9W` (Xcode: not a free team); keychain has only "Apple Development"
(local testing, cannot be notarized) and "Nook Local Signing". No notary profile yet. Xcode 26 notarytool/stapler present.
Installed copies (v10 and earlier) accept only "Nook Local Signing" (`certificate leaf = H"76a6…"`).

Done (not committed, not released):
- `Updater.signedByNook`: running app's designated requirement; a copy that satisfies `legacyRequirement`
  (old releases, leaf 76a6…) also accepts `releaseRequirement` (Developer ID, team T2KMY2TV9W, `dev.nook.app`).
  Contributor builds (ad-hoc, other certificates) take only builds signed like themselves. Checked with a test
  binary built from the same function: signed like old releases it accepts a Developer ID stand-in (Claude.app with
  its own id + team in the requirement) and the installed Nook; ad-hoc it rejects both; Claude.app fails the real
  Nook requirement.
- First notarized release notes tell users to turn Nook off and on in Full Disk Access and Accessibility
  (TCC keeps the old signature's requirement; the toggles look on but do not work).
- `install.sh`: identity order NOOK_SIGN_IDENTITY → Developer ID (by SHA-1) → Nook Local Signing → ad-hoc; the
  bridge dylib now gets the same signature + hardened runtime; `NOOK_TIMESTAMP=1` adds a secure timestamp.
  `./install.sh --build-only` builds and verifies (`codesign --verify --strict --deep`) with Nook Local Signing.
- `release.sh`: Developer ID + notary preflight, notarize zip → staple app → DMG (Applications link) → sign →
  notarize → staple → `spctl` both → publish Nook.dmg + Nook.zip. `--local-signing` = bridge release.
- Docs: DEVELOPMENT.md → Releases (one-time setup), CLAUDE.md, README/SECURITY (text for the notarized release).

2026-11-06 18:27: the user created "Developer ID Application: Oleh Yaitsov (T2KMY2TV9W)" (SHA-1 D0095295…, G2 CA,
valid until 2027-12-06, about 13 months: renew before then; updates survive it, the requirement names the team) via
developer.apple.com + a CSR from Keychain Access (Xcode's Manage Certificates failed with "only the Account Holder").
`NOOK_TIMESTAMP=1 ./install.sh --build-only` picked it by itself: app and dylib signed, secure timestamp,
`codesign --verify --strict --deep` valid, DR = the team form, `releaseRequirement` accepts the build, the installed
local-signed Nook fails it; `spctl` says "rejected, source=Unnotarized Developer ID" (expected before notarization).
18:35: the user stored the notary profile `nook`. Test notarization of build 1.22 (same steps as release.sh, nothing
published): zip Accepted in 19 s, log without issues; app stapled, `spctl` accepted "Notarized Developer ID"; DMG
(Applications link) signed, Accepted, stapled, `spctl --type open` accepted. The bridge from a copy with a Safari
quarantine flag on every file loads the dylib in /usr/bin/perl (`{"ready":true}` + a state line), read-only.
Not checked: first launch of a downloaded copy (a second Nook cannot run next to the user's), the in-app move
bridge → Developer ID, `release.sh` end to end (it publishes).

Order (each release needs the user's check first):
1. User creates the Developer ID Application certificate and the notary profile `nook` (DEVELOPMENT.md → Releases).
2. Commit code + dev docs; merge to main WITHOUT README/SECURITY; `./release.sh --local-signing` (bridge).
3. Wait until old copies took the bridge (or accept that the few v10 users reinstall by hand).
4. Merge README/SECURITY, `./release.sh` (first notarized). Then check on a fresh download: DMG opens with no
   warning, `spctl` says Notarized Developer ID, Now Playing works (perl loads the dylib from a quarantined copy),
   the bridge copy updates itself to the notarized build.
5. Local daily build switches to Developer ID by itself: macOS asks for permissions once more.

Not verified yet: the whole notarization path (no Developer ID certificate yet), a Developer ID build passing
`signedByNook` inside the running app.
Later: Homebrew tap (`brew install --cask olehmrvz/tap/nook`, `auto_updates true`); not in homebrew/cask yet
(too few stars for its notability rule).

## Full review and fixes (2026-11-07, branch `olehmrvz/feature`, not committed)

Review of `c8491ec` by five Orca workers (3 Codex, 2 Claude), every finding checked against the code. Rejected: "agent
starts dictation through `dictate:start`" (the check exists). Fixed:
- `--answer`/`--dictate` check: a chain that reaches launchd without an app or a `/System` process is refused
  (an agent's `( … & )` got ppid 1 and passed). Side effect: Orca/herdr/tmux terminals are refused too.
- Permission card: invisible, bidi and no-break characters shown as `⟨U+…⟩`, 40+ spaces as `⟨␠×N⟩`; the line chip
  counts wrapped lines. "Always" for folders shows the full path.
- `--timer inf|1e18` crashed (Int trap), `nan` never ended: 0 < minutes ≤ 24 h, `format` clamps.
- Main thread: Cuely's engine on its own queue (`stop()` no longer creates the input node), API key presence without
  decrypting (`Keychain.exists`), file icons by type, Agents tab "Connect" off main.
- Stale `previousApp` (paste/Esc into an old app), hover panel closing while a field is edited, islands lost while
  resting or stuck after the prompter, Pomodoro "+5 min" (hidden in Pomodoro), double-click kill, volume HUD toggle
  without restart, volume keys swallowed on HDMI outputs, ducked level kept in defaults and restored after a crash,
  AI copy of the selection waits up to 1 s, paste waits for the target app, cover art decoded and scaled off main,
  quicklink values encode `& + = ? #`, the geocoder gets the rounded position, two tooltips translated (check.py now
  sees `+` on the next line).
Verified: full `swiftc` build (no new warnings), check.py 683/683, extracted functions in a scratch binary (orphan
refused, Orca app child accepted, reveal/format/encoding/device UID cases). Not run in the real app (needs install).
Left: TOCTOU of the staged update and of the bridge dylib (same-user attacker, low), Spotify cover fetch not listed
in README (the user asked not to edit README now).

## Home redesign: six directions (2026-11-07)
- The Figma page "Nook" (0:1) was empty: the A–D variants from 2026-10-26 are gone (not on any page).
- New frame "Главный экран — 6 направлений (7 нояб. 2026)" (node 382:2):
  https://www.figma.com/design/TKW5XTlfIPhx9RdAb4TVoA?node-id=382-2
  A «Сейчас» (397:2) one urgent item large + queue; B «Обложка» (384:2) artwork colours the panel;
  C «Пульт» (398:2) agent columns waiting / working / done; D «День» (399:2) day timeline + three cards;
  E «Плитки» (400:2) saturated widget tiles; F «Команда» (401:2) the existing launcher (⌥Space) on Home.
- One demo data set on every board: Claude «nook» waits 2 min (swiftc), Codex «atlas-api» works 45 min, «landing»
  done at 17:45; focus 17:40–18:30 (25 of 50 min left); meeting 18:30; Claude limits 42 % / 68 %; panel 780 × 326 pt,
  black band under the camera kept. Keys shown are the app's real ones (⌘1–⌘0 tabs, right ⌥ dictation). No Enter-to-approve:
  the panel only takes the keyboard for text fields. Built as HTML and imported with
  html_to_figma (plain layers, not components). Ring arcs are SVG paths: dashed strokes break in the import.
- USER liked D «День» and E «Плитки», found E too bright. Round 2 (frame 392:2, right of 382:2), grounded palette
  (graphite tiles, colour only in icon / number / progress; bright only the "now" marker and the waiting agent):
  G «День и плитки» (402:2) short day strip + four tiles; H «Тихие плитки» (403:2) the E grid in graphite;
  I «Циферблат» (404:2) a 12–24 h clock face (events outer ring, agent runs inner rings) + four tiles.
- Round 3 (frame 407:2, right of 392:2), new ideas on the same base (time from D, modules from E, round-2 palette):
  J «Горизонт» (408:2) three zones was / now / next, the now zone widest; K «Сводка» (412:2) a few sentences with
  inline pills and buttons + three tiles; L «Табло» (410:2) a departures board: time (split-flap digits), what, detail,
  status, action, music ticker. Import pitfall: text that wraps around inline pills breaks in html_to_figma —
  build such text as one flex row per line.
- USER: «Горизонт» is interesting but «было» is pointless. v2 (414:2, in J's place; v1 408:2 dimmed in the free slot):
  only forward — Сейчас / Скоро (до 19:00) / Позже (вечер); the farther, the smaller and quieter. The finished agent
  (landing) sits in Сейчас with «Посмотреть»; the line under Сейчас is the focus progress.
- USER picked G «День и плитки» and H «Тихие плитки» (2026-11-07) and asked to design the whole app in both.
  Round 4 frame 416:2 (right of 407:2): G column left, H column right. Inventory of every screen came from code
  (tabs, header, collapsed notch, islands, HUD flashes, settings panes) and drives the content.
  - [x] Batch 1: tabs in G and H — Главная, Агенты, Буфер, Полка, Календарь, Таймер, Заметки (417:2–430:2).
    One demo story everywhere: pomodoro focus 2 of 4 (17:55–18:20, 14:32 left), meeting 18:30 overlaps focus 3.
  - [ ] Batch 2: shared screens — Поиск (results / calculator / AI answer), agent question and plan cards, Cuely
    (tab + prompter), Зеркало, power card, keyboard lock.
  - [ ] Batch 3: collapsed notch states, islands, HUD flashes; Settings window; empty / no-access states.
  Generator (scratch, not in the repo): gen.py, round2.py, round3.py, app.py + build.py (fonts) + snap (WebKit render).
- USER rejected round 4: "looks like no redesign at all" — worst: too close to the current app, no common style.
  Cause: tabs were redrawn from the code inventory one to one in a darker palette (a reskin), mass-produced.
  Round 4 frame renamed "черновик, не принят". USER chose: per tab, 3–4 truly different ideas, like Home.
- Round 5 (frame 452:2, right of 416:2): «Общий язык» board (surfaces, colour = meaning, type, project monogram,
  5 rules) + Агенты: Решения / Приборы / Лента / Сцена; Буфер: Колода / Полки по типам / Закреплённое и сегодня /
  Мастерская (453:2–461:2).
- USER picks (2026-11-07): Агенты = «Лента» crossed with H tiles; Буфер / Полка / Календарь / Заметки = H from round 4;
  Таймер H "в целом неплохо". Asked: compact Claude limits, Codex limits with any window (5 ч, неделя, месяц, N ч),
  «Всегда» in the request card, no time column in the feed.
- Round 6 «выбранное» (frame 463:2, right of 452:2): new Агенты «Лента × плитки» (464:2) + «Лимиты компактно» sheet
  (467:2: one line per provider, windows from the service, pace ↑ / low / no-data states, details on click) + clones
  of the chosen H screens and both Home variants (G 417:2 / H 418:2 — one still to choose).
- Таймер: USER asked to merge the G timer (427:2) into the chosen H one. Done in round 6 (469:2, replaced the H clone):
  ring + quick start + «Добавить» from H, the G pomodoro strip with the meeting lane instead of «Следом».
- USER: fewer Claude colours. Palette now: attention «ждёт тебя» = yellow #FFD24D (yellow edge on graphite, no warm
  wash), focus = Nook pink #FF6FAE, agent glyphs neutral #E6E6EA (Claude like Codex), deny = red #FF6B6B, mockup
  wallpaper cool blue/violet. Chosen set re-rendered: frame 471:2 «Раунд 6 · выбранное» replaced the old 463:2.
- Round 7 (frame 471:3): islands — Ушки / Капля / Карточка / Строка дня; collapsed notch — Буквы / Нить / Числа.
- USER rejected round 7 (frame dimmed, renamed): separate cards are wrong — notifications grow only from the notch.
  «Капля» was "более менее", but the bottom lifetime strip is pointless. Collapsed notch: keep it as it is in the app
  now (project letter under the blinking cursor), none of the three ideas. USER wants notifications to be excellent.
- Round 8 (frame 491:2, right of 471:3): «Капля» as one system, no strip, no cards. Colour of meaning = a halo
  around the icon inside the drop (bottom glow was tried and read as a strip again). Boards: средняя «Сообщает»
  (492:2, 8 kinds: агент закончил, встреча, сообщение, звонок, фокус, AirPods, загрузка, трек; 460 × 38+68 pt),
  большая «Спрашивает» (493:2: разрешение, вопрос, план, нагрузка на Mac; 540 pt, stays until answered),
  поведение «Как живёт» (494:2: grow storyboard 0,12/0,26/0,34 с, hover holds + ×, queue «ещё 2» right of the
  camera, unanswered → collapses to the yellow letter, focus holds drops), подача «Насколько сочно» (495:2:
  Чёрная / Ореол (recommended) / Ушки).
- Home: two Home screens are in the chosen set because Home G vs H was never picked; recommended H + G day strip.
- USER liked round 8 and asked for one more round "чтобы убедиться, что это лучшее", ideally better. Round 7 frame
  471:3 is no longer on the page and round 8 sits at x 16887 (moved outside this session).
- Round 9 «Капля, докрученная» (frame 498:2, right of 491:2): 499:2 сравнение 8 → 9 on the same events;
  500:2 «Три высоты» (вспышка — ears only, капля 62 pt, большая капля); 501:2 «Новости» (band beside the camera
  carries meta: «Claude · 45 мин» / diff, «18:30» / countdown, app / count; focus warns that the meeting hits
  focus 3; two agents done = one drop with two rows); 502:2 «Нужен ответ» (540 pt, 16–20 pt lower than round 8);
  503:2 «Мелочи — вбок» (AirPods, трек, загрузка, тихий чат as ear flashes; system flashes stay as in the app);
  504:2 «Растёт на шаг» (flash → drop on hover, hover detail, click grows the drop into the Агенты panel, queue «+2»,
  unanswered → yellow letter, focus holds drops). Form: 12 pt concave corners. Halo look kept.
- Spacing pass (USER: "проверь каждый дизайн на паддинги и гэпы"; pointed at a flash with unequal sides and the
  collapsed timer pressed to the right edge). Measured every drop / flash / tile with a WebKit + JS audit
  (scratch: measure, audit_drops.js, audit_tiles.js, report.py). Grid now: notch shapes EDGE 18 on both sides (ear
  content pinned to the edges, not centred), body 6 under the band, bottom 16, GAP 10, list rows 6, ≥ 10 pt to the
  camera; drop heights are computed from their blocks. Tiles: 14 inner padding, 10 gaps, exact column widths; Агенты
  feed lost its third event row to fit 262 pt (limits line was 2 pt from the bottom). Result: 0 flags in rounds 8/9,
  tiles all ≥ 14 except known artefacts (cover-art blob, big-number line boxes, a full-bleed image). Re-imported in
  place: round 6 boards 510–518 (471:2), round 8 530–533 (491:2), round 9 534–539 (498:2). Height notes updated
  (R9 vs R8: 100 vs 104, 168 vs 172, flash 38 vs 104). G Главная (473:2) is gone from 471:2 (removed outside this
  session) — confirm H as Home.
- Next concrete action: the user compares rounds 8 and 9 and picks; then Home
  G or H, Поиск (4 ideas), agent question / plan cards inside Лента, empty states, Cuely, Зеркало, Батарея,
  Блокировка, Настройки.
