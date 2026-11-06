# Settings window (branch `olehmrvz/feature`, 2026-11-06)

Goal: a real Settings window instead of the long menu: clear sections, permission status, updates with the
signature of the running copy, and a "thank the author" page with USDT addresses.

Constraints:
- A parallel agent (branch `olehmrvz/certificate`, not committed) changes `Updater.swift`, `NowPlaying.swift`,
  `install.sh`, `release.sh`, README/SECURITY/DEVELOPMENT/CLAUDE.md. This branch does not touch `Updater.swift`,
  `install.sh` or `release.sh`; docs only in lines outside its hunks, so both merge cleanly.
- No file access on the main thread (permission prompts block it): checks run on a serial queue.
- An accessory app has no main menu: the window handles ⌘W itself and gives focus back to the previous app on close.

Design: NSWindow + SwiftUI `NavigationSplitView`, sidebar with coloured icon tiles (like System Settings),
grouped forms. Panes: Основные, Вырез, Уведомления, Агенты, Приватность | Обновления, Спасибо автору.
Menu bar menu keeps quick actions only (open, clipboard, coffee, Settings…, check updates, thanks, quit).
The gear in the panel opens the window. `Nook --show settings[:pane]` opens it from the command line.

Addresses (decoded from the wallet's QR screenshots with CIDetector; Tron base58check verified):
- USDT TRC-20: `TDQnp3XjR1yjFhDTxUfhgRAA9YuoitR9vd`
- USDT ERC-20: `0x64aF41413b60d36eBf0148eA303AC3087301b2e8`

Steps:
- [x] `Sources/SettingsWindow.swift`: window controller, state, panes, QR codes.
- [x] `App.swift`: short menu, `settings` command, gear → window (`NotchModel.onOpenSettings`).
- [x] Build (no new warnings), every pane captured in dark mode; the TRC-20 QR decoded from a screenshot of the
  window equals the address; both addresses in the source equal the wallet's QR codes.
- [x] Docs: CLAUDE.md flags, DEVELOPMENT.md notes, README updates line.

Discoveries:
- Full Disk Access status comes from `NotificationWatcher.hasAccess` (the access the features actually use;
  lags up to a minute after granting), not from probing `TCC.db`.
- On 2026-11-06 18:42 the FDA entry for dev.nook.app was switched off (auth_value 0, csreq = Nook Local Signing,
  matches the installed build): the window correctly says «Нет доступа».
- `.toolbar(removing: .sidebarToggle)` has no effect in an AppKit-hosted NavigationSplitView: the toggle stays
  (cosmetic). Column width needs `navigationSplitViewColumnWidth(min:ideal:max:)` with the bridged toolbar.

Open:
- Not checked: light mode, the ERC-20 tab on screen (same code path as TRC-20), clicking through the real gear
  (synthetic clicks are not used on this Mac). Not committed (the user has not asked yet).
- Next requests from the user: dictation (research: MorsCast is AGPL-3.0 — no code copying; Apple
  DictationTranscriber on macOS 26+ covers ru/uk/de/en), UI in ~10 languages, more MorsCast features.
