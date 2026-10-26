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
