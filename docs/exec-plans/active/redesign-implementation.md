# Redesign: implement the chosen design in the app

Started 2026-11-07. Design source: Figma "Sandbox", page "Nook" (0:1).

## Objective

Implement in SwiftUI only what the user chose (USER, 2026-11-07: "должно было остаться только то, что мы будем
выполнять … восьмой пропускай, девятый делай, приступай к … приложению"):

- Common language + tabs from round 6 «выбранное» (frame 471:2): H Главная (511:2), Агенты «Лента × плитки» (512:2)
  with «Лимиты компактно» (514:2), H Буфер (513:2), H Полка (515:2), H Календарь (516:2), Таймер «H × шкала из G»
  (517:2), H Заметки (518:2), style board «Общий язык» (510:2).
- Notifications = round 9 «Капля, докрученная» (frame 498:2, boards 534–539). Round 8 (491:2) is skipped.
- Collapsed notch stays as it is in the app now (project letter under the blinking cursor).

## Constraints

- No Claude colours: attention «ждёт тебя» = yellow #FFD24D, focus = pink #FF6FAE, agent glyphs neutral #E6E6EA,
  deny = red #FF6B6B. Colour = meaning; one white primary button per screen.
- Spacing grid (USER asked for exact, equal spacing): tiles 14 inner padding, 10 between tiles, radius 22;
  notch shapes: content EDGE 18 from both sides (pinned to the edges), body 6 under the band, bottom 16,
  GAP 10 between blocks, list rows 6, ≥ 10 pt from band content to the camera.
- Tab area is fixed: 744 × 262 pt on this Mac (38 pt notch). Band under the camera stays pure black.
- Keep behaviour: every action, hotkey, setting and permission flow that exists today must keep working.
- Do not commit unless asked. The tree already holds uncommitted code-review fixes (19 files); a patch of them
  before this work is saved in the session scratchpad (review-fixes-before-redesign.patch).
- Never make the panel key on open; no work on the main thread for files/AppleScript; idle CPU ≤ 0.5 %.
- UI strings: Russian key + English entry; run `python3 Sources/Localization/check.py`.

## Steps

- [x] 1. Foundations in `Theme.swift`: palette tokens, surfaces, `Tile`, tile icon chip, monogram cell, pill kinds
       (primary / ghost / deny / go), spacing constants; ambient glows without Claude coral.
- [x] 2. Header H: icon tabs, active one in a white circle; calendar and timer right of the camera; status capsule.
- [x] 3. Главная H: music (2 cols), next event, agents (tall), weather, limits, timer — 4 × 2 grid of tiles.
- [x] 4. Агенты «Лента × плитки»: session tiles (filter) left; feed right: request card with Разрешить / Всегда /
       Отклонить, events, finished turns; compact limits line + details popover.
- [x] 5. Буфер H (tiles by type), Полка H (file tiles + drop tile + «6 файлов»), Календарь H, Таймер (ring, pomodoro
       strip with the calendar lane, quick start, add), Заметки H (note tiles + editor).
- [x] 6. Notifications round 9: flash in the ears for trivia, drop (62 pt body) for news, big drop for questions;
       band beside the camera carries who / when and state; halo around the icon; merged drop for two agents;
       hover grows a step; click opens the panel tab; queue «+N»; unanswered big drop collapses to the yellow letter.
- [x] 7. Settings window in the common language (USER, 2026-11-07: «дизайн настроек подтяни, чтоб было лучше»).
- [x] 8. Verification: build (Developer ID, install.sh and release.sh), tabs via `--show`, request and done drops via
       agent-hook events (README screenshots), idle CPU (item 7 below), localization check. Not verified live: a real
       AirPods switch and «Вернуть на Mac», the launcher's empty field and AI answer, hover growth of drops.

## Verification log

- Fast check: scratchpad `typecheck.sh` (swiftc -typecheck, ~11 s). Full: `./install.sh` then `Nook --show <tab>` and
  `screencapture -x -R 490,0,820,330`.
- Steps 1–4 built and installed; Home and Agents captured and compared with Figma (H grid, header, feed, limits line).
  Agents checked with demo hook events (Edit / Bash + PostToolUse, a done turn, a Bash PermissionRequest), ended with
  SessionEnd; a real AskUserQuestion from the user's own "design" session was on screen and left untouched.

- Steps 5–7 built and installed. Captured: Timer, Shelf, Calendar (real reminders), Notes (empty), Clipboard (empty:
  see below), request drop (demo Bash PermissionRequest), one finished turn, two merged turns, Settings panes
  (general, notifications, dictation, search, access). Hover growth of drops not exercised (no synthetic pointer).
- Settings performance (`sample` while switching 36 panes in 9 s via `--show settings:<pane>`): before — main thread
  idle 3 %, NSHostingView.layout 1554 samples, CA commit 2227; after — idle 27 %, layout 181, commit 447 (≈ 40 ms
  per switch instead of 250+). Idle with the window open: main thread busy ≈ 3 %, no settings bodies evaluated.
- Localization: 774 entries, all used, 0 missing (check.py now also knows Settings* wrappers, subtitle:, footer:).

## Decisions / discoveries

- New files: `HomeTiles.swift` (Home), `AgentsFeed.swift` (Agents), `LimitsLine.swift` (limits line, details,
  `LimitWindow` with pace / low states). Tokens in `Theme.swift`: `Tone`, `Surface`, `Spacing` (not `Grid`: SwiftUI
  has a `Grid` view), `Tile`, `TileIcon`, `TileHeader`, `Monogram`, pill kinds `.ghost/.deny/.go`.
- AgentHub keeps an in-memory feed `events` (last 40 tool calls, ok / failed, test / commit / push checks); there was
  no history before. No diff counts exist, so feed rows show tool + target + result only.
- Project colours (collapsed notch and monograms) no longer include yellow or pink: those mean "waits for you"
  and focus now.
- Hover no longer scales cards (USER: the yellow Agents tile hid under the clip on hover); brightness only.
- While a question or plan is pending, the limits line in the feed hides (the card needs the whole tile).
- Panel glow is one calm blue glow (H), plus a soft yellow one while a request waits.
- Requests no longer pop the whole panel open: they come as a big drop (30 s, held by the pointer), then the collapsed
  notch keeps the yellow letter. A command or plan longer than the drop shows can only be approved in the panel
  ("Посмотреть"): the drop hid blank-line-separated fields at first — fixed, blank lines are dropped and every line
  must be visible.
- Two agents finishing together merge into one drop (`Island.Kind.agentsDone`); queue count shows as «+N».
- Settings: own sidebar + SettingsPage/Group/Row/Toggle/Picker (SettingsKit.swift) instead of NavigationSplitView and
  a grouped Form; panes in three groups; «Вырез» merged into «Уведомления» (`settings:notch` still opens it);
  «Приватность» is «Доступы» with every macOS permission and what it is for; the alias list is lazy. No global tint
  (USER: green text in Settings "дёшево и ужасно").
- Clipboard and shelf "Очистить" are two-click (ConfirmButton). During a capture of the Clipboard tab the history was
  cleared (clipboard-events.log 11:44:54Z "clear removed=57"; no backup, no Time Machine) — reported to the user.
- Dictation stopped because this build lacks Accessibility (and Full Disk Access): a different signing identity than
  the copy the permissions were granted to. Only the user can re-enable them (Settings → Доступы → «Открыть…»).

- Limits details (USER 2026-11-07: the popover was cut at the top — about 300 pt in a 262 pt tab) now replace the
  feed inside its tile: a column per service, the line at the bottom closes them (`--show limits` opens them).
  A new request closes the details. Without limits the line does not open anything.
- Code review (high, 10 findings) fixed:
  - the request drop enabled "Разрешить" by a character count; now `reportsWhole` measures the drawn text (the copy
    drops the inherited line limit, or it always "fits"). Scratch probe: short / 60 / 66-char / two lines → whole;
    130 chars, 40 tabs (drawn as "ls…"), CJK, three lines → "Посмотреть". Plan steps are measured too and revealed;
  - a request while the prompter shows opens the panel, as before drops;
  - open feed calls get "не выполнено" when the turn ends (Stop / next prompt); no tool_use_id → newest open call;
  - while the screens rest only finished turns wait; on wake calls older than 30 s and other news older than 10 min
    are dropped; a fourth agent finishing gets its own drop instead of vanishing from the merged one;
  - the drop halo is masked under the band (black band rule); ConfirmButton ignores the second click of a
    double-click; the music glow animation goes through Motion.
  - Kept on purpose: `runsUnderAgent` refuses tmux / ssh / launchd-adopted callers (documented in DEVELOPMENT.md:
    otherwise an agent's nohup or tmux could approve its own request).
- Second review (5 findings) fixed: limits details open from the empty Agents tab and the Home «Лимиты» tile too;
  a new request resets them in the model (any tab); the Home timer bar uses the phase tone (pink focus, not coral);
  a bare six-digit code is no longer a colour (needs `#` or letters and digits); a question drop answers in one
  click only when the question is drawn whole, no option has a description and every label fits at full width
  (scratch probe: long title → panel, four long options → «Ответить»).
- USER round (7 нояб., afternoon): the Agents feed got a caption row («Лента» / «Лимиты · осталось») so its tile
  starts level with the session tiles (request cards measured offscreen: permission 163 pt, question and plan fit);
  the empty Agents screen is centred; the agent-done drop: halo tight and in the letter's colour, the message goes
  on to three lines on hover instead of repeating, a close button in the band for every non-flash drop.
- Shelf opened scrolled 7.5 pt down (first row cut): `Entrance` combined offset + scaleEffect on a ScrollView;
  either alone is fine (offscreen probe read the NSScrollView clip origin: 7.5 → 0). The scale is gone.
- Session tiles swapped places on every tool call when two agents worked (sorted by last event) and slid over
  each other: now by state, then newest session first.
- Third review: a question or plan now fills the feed tile itself (`requestFillsTile`: the tile gets the yellow
  edge, no nested card) — offscreen probe: all four feed cases 232 pt (the permission command box 62 → 58 pt);
  the done drop grows on hover only by what it shows (`DropView.moreHeight`: short message, no facts → 0).
- System volume/brightness HUD and dictation: the Accessibility entry in TCC.db was still bound to the old
  "Nook Local Signing" leaf certificate (csreq H"76a6…"), the Developer ID build does not satisfy it; Full Disk
  Access matched. The user must remove Nook from the list and add it again (or `tccutil reset Accessibility
  dev.nook.app`). Settings → Доступы now says so; dictation re-applies when Accessibility changes (no restart).
- Background agents started: launcher redesign in Figma (right of everything) and the Agents feed content
  rethink (frame at x 22887, y 2400). Icon round 1 (546:2) rejected by the user — next round needs direction.
- Visual checks of the limits details were done offscreen (scratch renderer in the session scratchpad, all sources
  plus a main that draws the views): the screen was locked. Not yet seen in the real notch.

## Round 2: feed «Что изменилось» and launcher «Главное совпадение» (USER chose, 7 нояб.)

Figma: feed concept C = frame 554:796 inside 554:2 (generator: session scratchpad agents-feed/build.py, `tab_c`);
launcher B = row «B · Главное совпадение» in 552:2 (generator: scratchpad launcher/gen.py). The user also liked A
«Группы» for the launcher; take its group captions and «Tab — спросить AI» where they fit.

Feed C — data checked in this session's Claude Code log (toolUseResult = hook tool_response, assumed):
Edit/MultiEdit/Write results carry `structuredPatch` hunks with "+"/"-" lines; Write has `type` create/update;
Bash has stdout/stderr, a push also `gitOperation.push.branch`. Fallbacks when a field is missing: old/new
strings, Write content lines, `git commit` stdout "[branch sha] title" or `-m`, Codex apply_patch text.
Steps:
1. [x] AgentHub: `changes` (file ± lines merged per file, tests with counts, commit / push, failed command) built
   at PostToolUse(Failure); tool calls that only read are not kept. Replaces `events`.
2. [x] Feed: caption «Изменения» with the limits line on its right; one-line request row (approve only when the
   command is drawn whole, else the full card); change rows; done rows «ответ: …» with «Ответить».
3. [x] Verified: parser on 13 sample payloads (Edit patch / no patch, Write create, jest / pytest / XCTest counts,
   commit from git output and heredoc -m, push branch, failed command, denial, Read ignored, Codex patch per file);
   offscreen render of the tab; live demo session `demo-feed-1` (4 rows, Read dropped), ended with SessionEnd.
   The request line takes two lines of command at most; «Разрешить» only when both are drawn whole.
   Accessibility: stale entry reset with `tccutil reset Accessibility dev.nook.app`, the user granted it again
   (16:01, csreq matches the Developer ID build).
Launcher B:
4. [x] Read Launcher.swift, then build the B layout: selected result as a big card on the left (actions, alias,
   keys, opens, windows), short list on the right; calculator and AI answer full width; empty and no-results.
5. [x] Verified live with `--show launcher:<text>`: results («safari», «saf»), calculator («120 eur в uah», full
   width), nothing found («qzxwvj»: violet «Спросить AI» card + Google / Словарь + what was searched). Not seen:
   the empty field (needs the keyboard) and the assistant's answer (needs Tab). New tile kind `.accent(Color)`.
   Not done from A «Группы»: group captions in the list (the user liked them too) — offer as a next step.
7. [ ] OPEN (one case left, watch for it) — idle CPU spikes: twice 23–25 % for minutes (rule ≤ 0.5 %).
   - Fixed, panel open: `AmbientGlow` breathed with a SwiftUI `withAnimation(.repeatForever)`, so SwiftUI
     re-rendered and laid out the whole panel on every display frame while it was open (`NSHostingView.layout` +
     `HostingScrollView.updateValue`: each frame re-lays out the open tab's ScrollView). Build 57, panel open and
     untouched: 13–19 % on Главная / Полка / Поиск / Агенты, 0.9–3.3 % without the breathing. v60 (video session)
     shipped the glow static: 1.1–1.8 % open, 0.2–0.4 % collapsed. After v60 (fix-bugs session) the breathing is
     back in Core Animation: `AmbientGlow` is an `NSViewRepresentable` — radial `CAGradientLayer` spots, the
     breathing (0.97 ↔ 1.05, 5 s) as a `transform.scale` animation, the black band as a gradient mask, 0.8 s
     cross-fade when the glows change, paused by `\.motionPaused` / Reduce Motion; 1.3–1.7 % open, 0.5 % collapsed.
     Colours match the SwiftUI glow (30,37,62 / 18,23,41); it breathes (edge x 574 → 527 between 0.8 s and 4.8 s);
     the attention glow comes and goes with a demo PermissionRequest.
   - Ruled out, «tabs left alive after removal»: the 16:24 sample's ClipboardTab / LauncherTab bodies came with
     `NotchModel.select` in the same sample, i.e. tabs were being switched while it ran. An instrumented scratch
     build listed every NSScrollView in every Nook window each second (hidden or not): over 2 × 8 tab switches the
     panel held only the open tab's scroll views (two for a moment while switching); after each collapse 0 scroll
     views, 1–3 subviews; collapsed 0.4 %.
   - Ruled out, Settings window: open, then 8 panes switched, then closed — 0.6 / 0.4 / 0.5 % with the notch
     collapsed.
   - Not reproduced, collapsed spike (16:14 sample: main thread 63 % busy, `HostingScrollView` updates; the notch
     was collapsed in notch-now.png a moment later). Tried: every tab then collapse, 24 fast open/close cycles
     (3–5 % for ~10 s, then 0.2 %), Settings as above — all ≤ 0.6 %. In the panel a `HostingScrollView` exists only
     while expanded, so that sample most likely caught the panel open or closing — not proven. The 17:03 watcher
     sample was taken during the fix-bugs open-panel measurements (the process was idle in the sample itself).
     If it comes back: run a watcher (sample after a minute above 5 %) and capture the notch with the sample.
8. [x] Fourth review: the request line also takes Claude Code's `description:` line (tooltip); file rows keyed by
   full path (two `page.tsx` stay two rows); interrupted / declined runs give no outcome (`is_interrupt` read);
   cargo test counts summed over all "test result:" lines; Codex «Delete File» shows «удалён».
6. [x] AirPods (background agent; reviewed, installed): the macOS HUD cannot be turned off (system bundle hidden
   from Settings) — said to the user. New drop «AirPods переключились на iPhone · Вернуть на Mac» from the
   `audioaccessoryd` log line; Nook's own «подключены» drop also when only macOS saw the return. Idle 0.5 %, the
   `log stream` child ~0 %. Not seen live: a real switch and the button. DEVELOPMENT.md → AirPods switching.
   (was: macOS HUD only in Nook + «AirPods ушли на другое устройство · Вернуть» — a background agent owns
   Devices.swift / Notifications.swift / the new island kind; integrate, install and check when it reports.

- App icon (USER chose N2 «Чистая», lime, Figma 560:2): `make-icon.sh` draws a black N on a lime tile (E4FF8A →
  B4F22E, soft shadow, a bigger letter at ≤ 32 px); `install.sh` redraws the icon when `make-icon.sh` is newer than
  the cached `.build/AppIcon.icns` (releases go through install.sh too). Checked: the installed icns at 256 px.

## Next concrete action

Done and released: the redesign is commit cbfd1d3, merged to main with the glow fix (07dfdea) and shipped as v60
(Nook 1.60, notarized, 2026-11-07; see github-launch.md). After v60: the Core Animation breathing glow is committed
on main (fix-bugs session; item 7); release it after the user checks the build. Still open: the collapsed case in
item 7 and the not-verified items in step 8.
