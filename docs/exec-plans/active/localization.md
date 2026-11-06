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

1. [ ] Infrastructure: `Sources/Localization.swift`, lproj folders, Info.plist, install.sh line, `Format` helpers.
2. [ ] Wrap code-built text with `L()` (script from the literal list, then review per file).
3. [ ] English table for every key; check that every key in the code has an entry.
4. [ ] Language picker in General.
5. [ ] Run in English with `NSShowNonLocalizedStrings`; open every tab and settings pane; fix what is missing.
6. [ ] English screenshots for the README (demo sessions only), README note about languages.
7. [ ] Russian still looks the same (spot check), merge-tree with certificate, commit.

## Progress

(empty)
