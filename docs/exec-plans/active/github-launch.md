# GitHub launch: the new design, one notarized release, Graphyte Labs

Started and finished 2026-11-07 (branch `olehmrvz/video`). Released as v60; the GitHub page, LICENSE and release
files are updated — every step below is done.

## Objective

USER: update the whole repository page for the new design — short English text about the product and each feature,
"Graphyte Labs" instead of "Oleh Yaitsov" (the user's future company), release files up to the latest version so
people can download only the latest. Wait until the logo is decided (the `olehmrvz/feature` agent changes it);
then do everything at once.

## Decisions (USER, 2026-11-07)

- Old releases v6 and v10: delete the releases **and** their tags after the new release is out (v10: 4 downloads,
  v6: 1). Irreversible — confirm the exact list right before deleting.
- LICENSE and README: "Graphyte Labs" everywhere (`Copyright (c) 2026 Graphyte Labs`, footer "Made by Graphyte Labs").
  The Developer ID certificate still says "Oleh Yaitsov" (macOS shows it as the developer; Settings → About reads it
  from the signature) until a company Apple Developer account exists.
- Bridge release (`./release.sh --local-signing`) for v6/v10 copies: the user asked what it means (explained: no new
  Developer ID is needed; old copies only accept updates signed with "Nook Local Signing", so without a bridge they do
  not update themselves and must reinstall from Nook.dmg once). USER, 2026-11-07: **no bridge** — "удаляй те старые
  версии и выставляем только подписанный эпл приложение". Deleting v6/v10 (releases + tags) is authorized; do it right
  after the notarized release is published, so the Releases page and the README download link are never empty.

## Steps

- [x] Inventory: repo description/topics/homepage, releases v6 (Nook.zip) and v10 (Latest, Nook.zip), author name in
      LICENSE and README footer, `release.sh` publishes Nook.dmg + Nook.zip (Developer ID + notarization).
- [x] README draft (applied to README.md, draft file removed). Shorter: pitch, features by section in 1–3
      lines, install from Nook.dmg (notarized: no Gatekeeper workaround), permissions, privacy, build, support, license.
- [x] Logo decided (USER 2026-11-07 16:50): N «Чистая», a black N on a lime tile (`make-icon.sh` in feature).
- [x] Promo icon → `promo/assets/icon.png` (1024 px from make-icon.sh), both promos rebuilt and checked (16:57).
- [x] Idle CPU, panel open (item 7 in `redesign-implementation.md`): v60 shipped the glow static — commit "Glow: no
      breathing loop"; panel open 8–16 % → 1.1–1.8 %, collapsed 0.2–0.4 % (installed 1.58). After v60 the breathing is
      back in Core Animation (317cca6, on main; 0.4–1.1 % open, 0.5 % collapsed), not released yet. Item 7 stays open for
      one case: a spike with the notch collapsed, not reproduced.
- [x] Feature tree committed as cbfd1d3 (with the fix-bugs agent's clipboard tile and scroll-origin fixes).
- [x] The user authorized the release ("подписывай и собирай"); installed 1.58 checked for idle CPU.
- [x] Merged: main = develop = 5cae956 (feature cbfd1d3 + glow fix + README); main, develop and fix-bugs worktrees fast-forwarded.
      The feature worktree's uncommitted fix-bugs edits (identical to 317cca6, or an older plan draft) were discarded
      with the user's OK and the worktree fast-forwarded to main (d9e1b42, 2026-11-07).
- [x] Draft checked against the final code (changes feed, launcher card, AirPods drop added); icon → `docs/images/icon.png`.
- [x] Screenshots of the real app (English UI via the app's own AppleLanguages, removed afterwards): demo
      PermissionRequest (hero), demo Stop (done drop), `--show launcher:disk util` and `450 + 20%`; window-only capture
      (`screencapture -l`) on a neutral wallpaper. The Agents tab and Home were left out: they show the user's real
      sessions, music and weather.
- [x] USER (after launch): a full-width black band over the screenshots hid where the drop comes from. The captures
      now sit on the top of a Mac screen: wallpaper up to the top edge, a menu bar with menus and status icons left and
      right, a camera dot in the middle; the drop's ears meet the screen edge. Search and calculator canvases are
      2040 px wide so the menu bar shows beside the wide panel. No full-width black band in README images.
- [x] README and LICENSE (Graphyte Labs); SECURITY and the issue templates needed no change.
- [x] `./release.sh` from the main checkout: v60 "Nook 1.60 — a new design", Nook.dmg + Nook.zip, notes rewritten for
      users (SHA-256 kept).
- [x] Fresh download from `releases/latest/download/`: SHA-256 match; with a quarantine flag `spctl` accepts the DMG and the
      app as "Notarized Developer ID", stapler validates, version 1.60, Applications link in the DMG.
- [x] Releases v6 and v10 and their tags deleted; only v60 is left.
- [x] Description and topics updated; social preview uploaded (`promo/social/social-preview.png`, usesCustomOpenGraphImage = true).
- [x] The promo videos can go out now (`promo/POSTING.md`).

## Drafts for the repository settings

- Description: `Your MacBook notch, put to work: answer Claude Code and Codex from the notch, plus a launcher,
  clipboard, on-device dictation and more. Free and open source. By Graphyte Labs.`
- Topics to add: `launcher`, `clipboard-manager`, `dictation`, `open-source`, `macos-app`.

## Next concrete action

Done. After v60: the Core Animation breathing glow (fix-bugs session) is committed on main; release it after the user
checks the build.
