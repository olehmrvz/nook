# Agent features: reply, turn summary, usage, process watch, focus mode

Requested 2026-10-29. The user picked these from a list of ideas:
1. Reply to an agent from the notch (text goes to its herdr pane / tmux pane).
3. A richer "done" island: what the turn did (files, tests, commit).
4. Tokens and API-equivalent cost per session and for today; warning when the 5 h limit runs low.
6. A process that eats CPU / memory for a long time: island with "Завершить" (agents leave hidden processes).
7. Focus mode: one button starts Pomodoro, turns coffee on and hides notification islands during focus.
Deferred: 2 (start a new agent from the notch). Do it after the five above. Rejected: push to phone, fan control.

## Decisions
- Reply works only for sessions in herdr or tmux (Nook knows the pane), and only when the session is `done`
  or `idle`. Never while `waiting` / `attention`: the terminal may show a permission dialog, and typed text +
  Enter could pick an option there. Newlines become spaces (a newline would submit early). No CLI flag for it:
  an agent must not be able to type into another agent through Nook.
- Turn summary from hook events only (turn-specific, no git calls in the project): edited files (exists),
  test commands (`PreToolUse` Bash matching test runners) with result from `PostToolUse` (pass) /
  `PostToolUseFailure` (fail), `git commit` / `git push` that succeeded.
  `PostToolUseFailure` is added to Claude's hook events only (Codex: unknown event, not added). Existing installs
  get it when Nook's hook is already present (a hook the user removed stays removed).
- Usage: Claude transcripts (`transcript_path` from hooks; today = all `~/.claude/projects/*/*.jsonl` changed
  today), read incrementally by byte offset, deduplicated by message id + request id. Cost = API list prices
  (claude-api skill, cached 2026-10-06): input / output per model, cache read per model, cache write 1.25× (5 m)
  and 2× (1 h) input, fast mode 2×. Unknown model → tokens only. Codex: tokens only (no reliable prices).
  The user has a subscription: cost is labelled "по ценам API".
- Process watch: own processes only (same uid), sampled every 10 s with `proc_pidinfo`; CPU ≥ 90 % for 2 min or
  memory footprint ≥ 4 GB. Kill = SIGTERM, then SIGKILL after 3 s; a second click confirms. Never Nook itself.
  Context menu "Не показывать для <name>".
- Focus mode: quiet while the Pomodoro focus phase runs; breaks show islands again. Calls still show.
  Coffee on for the mode, previous coffee state restored at the end.

## Steps
- [x] 1 Reply: `AgentHub.canReply` / `reply`, `ReplyField` in the Agents tab, "Ответить" on the done island and the
      session card. herdr delivery checked in a scratch tab (text with quotes, `$HOME`, backticks, `;` arrives literally,
      `enter` submits). Not checked: typing in the field (no synthetic clicks), the tmux path.
- [x] 3 Summary: `TurnFact`, `checks(tool:input:)`, `PostToolUseFailure` (Claude). Checked with piped events: island
      "2 файла · ✗ тесты · коммит"; a pass after a fail shows ✓. Nook added only `PostToolUseFailure` to
      `~/.claude/settings.json` (9 other events byte-identical; backup `settings.json.bak-nook`).
      Not checked: that a real failing Bash fires `PostToolUseFailure` (documented as "Run after tool fails").
- [x] 4 Usage: `Sources/Usage.swift`; session line and "Сегодня" in the limits card. Numbers match an independent
      Python pass over the same files (today 25 M / $12.59 in Nook vs 26.4 M / $13.24 a minute later; this session
      242 M / $90.77 vs 243 M / $91.21). Memory peak 509 MB → 95 MB after 4 MB chunked reads.
      Not done: Codex tokens. Not checked: the low-limit island (5 h window was at 94 % left).
- [x] 6 Process watch: `Sources/Processes.swift`, island + two-click "Завершить", "Не следить за …", menu toggle.
      Checked: `yes > /dev/null` → island "yes · процессор 99% больше 2 мин" after ~2 min. Not checked: the kill
      button click (no synthetic clicks).
- [x] 7 Focus mode: `NotchModel.startFocusMode` / `endFocusMode`, Timer tab button, `--timer focus`. Checked: Timer
      tab shows "Фокус: уведомления ждут, кофеин"; `pmset -g assertions` shows Nook's PreventUserIdleSystemSleep during
      focus and none after `--timer stop`. Not checked: a real notification being held back.
- [x] Docs: README, DEVELOPMENT.md, CLAUDE.md.
- [ ] Deferred: 2 (start a new agent from the notch), Codex tokens.

## Verification log
- Build 1.18, no new warnings. Idle CPU with two agents working: 0.3–1.3 %, spikes up to 12 % while the pointer moved
  near the notch (event handling on the main thread, not the new code: ProcessWatch ≈ 4 samples in 8 s).
