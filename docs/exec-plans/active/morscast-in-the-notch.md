# MorsCast features in the notch (requested 2026-11-06)

Goal (user's words): "перенос функций из MorsCast — и поиск приложений, и всё-всё, чтобы это всё из чёлки
работало". Reference app: https://github.com/vladskrypchenko/morscast (fork of Tinycast).

Constraints:
- MorsCast/Tinycast is **AGPL-3.0-or-later**; Nook is MIT. No code is copied or translated from it: features are
  rebuilt from their behaviour and docs. Apache/MIT references (FluidAudio for Parakeet) may be adapted with a NOTICE.
- Build stays plain `swiftc` (no SwiftPM): only system frameworks, no vendored binaries.
- Everything starts from the notch: one hotkey opens the panel with a search field (the panel takes the keyboard only
  while a text field is focused, see CLAUDE.md); results and actions live in the panel (262 pt tab area).
- Branch `olehmrvz/certificate` (another agent) is not merged yet: avoid `Updater.swift`, `install.sh`, `release.sh`.

License decision (user, 2026-11-06, asked explicitly): Nook stays MIT; MorsCast code is NOT ported or translated,
features are rewritten from their behaviour (its docs, our specs). MorsCast: 963 Swift files, ~170k lines, no packages.

Done so far (commits on olehmrvz/feature): 1347a7b settings window · 4f004d7 dictation · 2fa0389 search, recorded
shortcuts, header · 5dcd858 calculator + currencies (ExchangeRate-API) · 49377bc aliases, item shortcuts, fallbacks ·
4f3a4c1 windows (Rectangle-style) · a5a299b snippets · 66391ed files, Apple Shortcuts, emoji, quicklinks, own commands ·
3c3a987 menu items + open windows · f7d9fe6 clipboard extras · 45ce2df crypto + Russian currency words · AI (this commit).
Left from MorsCast (LATER in the specs): AI chat window with history, MCP, Raycast extensions, window layouts/rooms,
OpenAI-compatible provider, dates/time zones in the calculator, uninstaller, backup/import. Then localization
(after olehmrvz/certificate is merged).
Offline checks are scratch CLIs compiled with the same source file (calculator cases, snippet files and
placeholders, emoji names, Apple Shortcuts list, commands); UI checks wait for the user (they were in a game). Not yet checked on screen by the user: dictation (key, paste), search on the second display,
aliases/shortcuts UI, softer glow in the real panel.

Decisions (user, 2026-11-06): dictation engine = Parakeet right away (not Apple's DictationTranscriber);
UI languages = EN RU UK DE ES FR PT-BR IT PL ZH-Hans + "as in system"; scope = dictation first, then everything else.

## Phases

1. **Dictation** (in progress, `docs/exec-plans/active/dictation.md` section below).
2. **Launcher core** — done (2026-11-06): recorded shortcut (default
   ⌥Space), opens on the pointer's display, apps + System Settings panes + Nook commands, ranking with layout
   fallback and usage boost, ↩ opens, ⌘↩ reveals. Specs of all MorsCast features (behaviour only, from its docs):
   scratchpad specs A-palette (calculator, currency, aliases, palette), B-tools (windows, snippets, clipboard
   extras), C-ai — summarised below as they are implemented.
3. **Launcher providers**: calculator + unit/currency conversion, quicklinks (URL templates), custom shell commands,
   Apple Shortcuts, system actions (lock, sleep, empty trash, dark mode, mute), file search, emoji picker,
   dictionary, fallback actions (search the web).
4. **Snippets**: keyword expansion in any app (Accessibility, event tap).
5. **Window management**: halves/thirds/quarters, maximize, center, next display (Accessibility); window switcher,
   menu-bar search.
6. **AI**: quick AI / chat and actions on selected text (needs an API key; Nook already knows Claude/Codex).
7. **Localization**: 10 languages + "as in system" (after `olehmrvz/certificate` is merged: strings in Updater).
8. Later / maybe: Raycast extensions (JavaScriptCore), backup/import, app uninstaller, Hyper key.

Also requested on 2026-11-06: user-recorded shortcuts for search and dictation (done: modifier alone, combination
or F-key; Carbon released events for hold-to-talk), Settings → Панель to hide header tabs/buttons (done), the notch
showing "Запись 0:07" / "Распознаю" while dictating (done, needs the user's check), softer glow (done: 8-stop
bell fall-off over a 1.4× ellipse), fewer descriptions in Settings (done: footnotes and pane headers removed).

## Phase 1: dictation

Engine: Parakeet TDT 0.6B v3 family, Core ML builds by FluidInference (CC-BY-4.0, credit NVIDIA, moondream,
FluidInference): Redux (≈ 222 MB, ternary encoder) and Ultra (≈ 632 MB, int8 encoder, best WER). 25 languages
incl. ru, uk, de, en, pl, es, fr, it, pt. Files pinned by revision; size + SHA-256 per file checked in Nook.

Contract (read from model.mil): Preprocessor(audio_signal [1,240000] fp32, audio_length [1]) → mel [1,128,1501],
mel_length; Encoder(mel, mel_length) → encoder (1024-d frames, 80 ms), encoder_length; Decoder(targets [1,1],
target_length [1], h_in/c_in [2,1,640]) → decoder, h_out, c_out; JointDecisionv3(encoder_step [1,1024,1],
decoder_step [1,640,1]) → token_id, token_prob, duration (bin of [0,1,2,3,4]). Vocab 8192, blank = SOS = 8192.

Steps:
- [x] `Sources/Parakeet.swift`: catalogue + pinned manifest (size + SHA-256 of all 18 files per model), downloader
  (staging folder, resume, rename when complete), engine (greedy TDT, 15 s windows cut at the quietest moment,
  decoder state carried across windows).
- [x] `Sources/Dictation.swift`: hold-a-modifier (default right ⌥) / double-tap toggle, AVAudioEngine 16 kHz capture,
  clipboard + ⌘V with the clipboard restored (transient type), Return/Escape tap while recording, sounds, case and
  space from 3 characters before the cursor, unload after idle (default 15 min).
- [x] Notch: live slot (mic + level meter while recording, spinner while recognising); `.dictation` island for notices.
- [x] Settings → Диктовка. `Nook --dictate start|stop|cancel|toggle`, refused from agent processes.
- [x] NOTICE.md (CC-BY-4.0 models, FluidAudio approach), README, DEVELOPMENT.md, CLAUDE.md, mic usage string.

Evidence (2026-11-06):
- Scratch CLI with the same `Parakeet.swift` on `say` speech: Ultra ru/uk/en/de correct except the brand name
  ("Nook" → "внук"); 7.3 s audio in 0.08–0.11 s; 31.7 s audio (windows of ≤ 15 s) in 0.19 s. Load: first 9.5 s, then 0.19 s.
  RSS 76 MB (weights live in the Neural Engine). Redux: slightly worse, first load 379 s (!), then 11.7 s.
- Downloader (same code) fetched Redux in 16 s; files identical to the reference; staging renamed only at the end.
- In Nook: with dictation on, a listen-only tap (keyDown + flagsChanged) exists; with it off, none (CGGetEventTapList).
  `Nook --dictate start` from this agent did nothing. Idle CPU 0.2 % with the build installed.
- Ultra copied into `~/Library/Application Support/Nook/Models/parakeet-ultra` from the verified scratch download.

Not verified (needs the user): holding the key, the microphone prompt, recording UI in the notch, paste into real
apps, the clipboard coming back, the in-app download button and progress.
Open: streaming "paste while recording"; Redux first-load time (try `.cpuAndGPU` for its encoder); ducking media.
