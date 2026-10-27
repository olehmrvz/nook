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
