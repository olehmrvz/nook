# English interface (first step of localization)

Objective: Nook speaks English or Russian by the system language, with a choice in Settings → General.
Then English screenshots for the README (the user asked for English images on GitHub, 2026-11-06).
The README goes to GitHub together with the release, after the user checks the build (user's choice).
Other languages (UK DE ES FR PT-BR IT PL ZH-Hans) come after olehmrvz/certificate is merged.

## Design

- Russian source text is the key. `Sources/Localization/en.lproj/Localizable.strings` holds English;
  `ru.lproj` is an empty table so macOS counts Russian as a localization. `CFBundleDevelopmentRegion` = en,
  so any other system language gets English.
- SwiftUI literals (`Text("…")`, `Button("…")`, `Toggle`, `Section`, `LabeledContent`, `Picker`, `.help`) are looked
  up by SwiftUI. Text built in code goes through `L("…")` (= `String(localized:)`); interpolations become
  `%@` (String) / `%lld` (Int) / `%lf` (Double) in the key, the same rules SwiftUI uses.
- Russian plurals: `Format.count(n, one, few, many)` keeps Russian rules; in English it uses `one` for 1 and
  `many` otherwise, both looked up in the table. Later languages need `.stringsdict`.
- Not translated: words the calculator reads in the input (units, currency names and stems), AI prompts,
  logs, anything stored on disk as data.
- Language choice writes `AppleLanguages` into Nook's own defaults and restarts Nook.
- `install.sh` copies `Sources/Localization/*.lproj` into the bundle: one line between unchanged lines, so the
  certificate branch still merges (check with `git merge-tree --write-tree olehmrvz/feature olehmrvz/certificate`).

## Steps

1. [x] Infrastructure: `Sources/Localization.swift`, lproj folders, Info.plist, install.sh line, `Format` helpers (cf3ca0a).
2. [x] Wrap code-built text with `L()` (482 places by script, reviewed per file; cf3ca0a).
3. [x] English table: 682 entries; `Sources/Localization/check.py` finds text without English and glued `Text("…" + x)`.
4. [x] Language picker in General (system / English / Русский), restart button; writes AppleLanguages + AppleLocale.
5. [x] Ran in English with `NSShowNonLocalizedStrings`: all 13 settings panes, Home, Agents, Timer, Shelf, search.
   Fixed: 4 glued literals, weekday phrase, «» quotes, dates in the region's language (AppleLocale en_UA).
6. [x] English screenshots in docs/images (demo sessions; own session hidden with SessionEnd for the capture):
   request, sessions, search, calculator. The limits card shows the real "Today … tokens ≈ $…" row (told the user).
7. [x] Russian checked after restoring the defaults; `git merge-tree` with olehmrvz/certificate clean.

## Progress

Done 2026-11-06/07 (see steps). Not checked in English: clipboard, calendar, notes tabs (private data, checked by
code only), islands other than "done", the teleprompter. Next: the other 8 languages after the certificate merge
(.stringsdict for plurals then; `Format.count` covers only Russian and English).
