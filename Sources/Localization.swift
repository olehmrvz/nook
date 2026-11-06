import AppKit

/// Text built in code, in Nook's language. The Russian source text is the key: Russian needs no table, and
/// `Sources/Localization/en.lproj/Localizable.strings` holds English. Interpolations become `%@` (text),
/// `%lld` (whole numbers) or `%lf` (fractions) in the key, the same as in SwiftUI's own `Text("…")`.
func L(_ value: String.LocalizationValue) -> String { String(localized: value) }

/// The interface language: the system's, or one chosen in Settings (macOS reads it from Nook's own defaults).
enum Language: String, CaseIterable, Identifiable {
    case system, en, ru

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L("Как в системе")
        case .en: "English"
        case .ru: "Русский"
        }
    }

    /// The choice in Settings, not what macOS picked from it.
    static var chosen: Language {
        get {
            let own = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String]
            return own?.first.flatMap { Language(rawValue: String($0.prefix(2))) } ?? .system
        }
        set {
            let defaults = UserDefaults.standard
            if newValue == .system {
                defaults.removeObject(forKey: "AppleLanguages")
                defaults.removeObject(forKey: "AppleLocale")
            } else {
                defaults.set([newValue.rawValue], forKey: "AppleLanguages")
                // Dates, weekdays and currency names in the same language; the region's formats stay (en_UA, ru_DE).
                let system = defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLocale"] as? String
                let region = system.flatMap { Locale(identifier: $0).region?.identifier }
                defaults.set(region.map { "\(newValue.rawValue)_\($0)" } ?? newValue.rawValue, forKey: "AppleLocale")
            }
        }
    }

    /// What the choice means on this Mac: macOS picks from Nook's languages in the order of the system's list.
    var resolved: Language {
        guard self == .system else { return self }
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return Bundle.preferredLocalizations(from: ["en", "ru"], forPreferences: system).first == "ru" ? .ru : .en
    }

    /// The language the text is shown in now (macOS picks it at launch).
    static var shown: Language { Bundle.main.preferredLocalizations.first == "ru" ? .ru : .en }

    /// A key that is not a literal in the code (the words of `Format.count`).
    static func text(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }

    /// A new language needs a new start: wait for this copy to quit, then open the app again.
    static func restartNook() {
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/bin/sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        restart.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? restart.run()
        NSApp.terminate(nil)
    }
}
