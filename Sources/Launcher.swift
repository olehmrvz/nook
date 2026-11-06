import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Settings {
    private static var defaults: UserDefaults { .standard }

    static var launcher: Bool {
        get { defaults.object(forKey: "launcher") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcher") }
    }
    /// Recorded in Settings → Поиск; ⌥Space until then.
    static var launcherShortcut: Shortcut {
        get {
            guard let code = defaults.object(forKey: "launcherKeyCode") as? Int,
                  let modifiers = defaults.object(forKey: "launcherModifiers") as? Int else { return .launcher }
            return Shortcut(keyCode: UInt32(code), modifiers: UInt32(modifiers))
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: "launcherKeyCode")
            defaults.set(Int(newValue.modifiers), forKey: "launcherModifiers")
        }
    }
    static var launcherApps: Bool {
        get { defaults.object(forKey: "launcherApps") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcherApps") }
    }
    static var launcherSettings: Bool {
        get { defaults.object(forKey: "launcherSettings") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcherSettings") }
    }
    static var launcherCommands: Bool {
        get { defaults.object(forKey: "launcherCommands") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcherCommands") }
    }
    /// Window commands (halves, thirds…) in the search.
    static var launcherWindows: Bool {
        get { defaults.object(forKey: "launcherWindows") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcherWindows") }
    }
    /// Google search and the dictionary under the results.
    static var launcherFallbacks: Bool {
        get { defaults.object(forKey: "launcherFallbacks") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcherFallbacks") }
    }
    /// Item id → the person's short word for it ("ff" → Firefox).
    static var launcherAliases: [String: String] {
        get { defaults.dictionary(forKey: "launcherAliases") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "launcherAliases") }
    }
    /// Item id → [key code, Carbon modifiers]: opens it from anywhere, without the search.
    static var launcherHotkeys: [String: [Int]] {
        get { defaults.dictionary(forKey: "launcherHotkeys") as? [String: [Int]] ?? [:] }
        set { defaults.set(newValue, forKey: "launcherHotkeys") }
    }
    /// Item id → [times opened, last opened (seconds since 1970)].
    static var launcherUsage: [String: [Double]] {
        get { defaults.dictionary(forKey: "launcherUsage") as? [String: [Double]] ?? [:] }
        set { defaults.set(newValue, forKey: "launcherUsage") }
    }
}

/// Nook's own actions, found by name like apps.
enum NookCommand: String, CaseIterable {
    case clipboard, shelf, notes, calendar, agents, timer, pomodoro, focus, coffee, keyLock, settings, updates, thanks

    var title: String {
        switch self {
        case .clipboard: "Буфер обмена"
        case .shelf: "Полка"
        case .notes: "Заметки"
        case .calendar: "Календарь"
        case .agents: "Агенты"
        case .timer: "Таймер на 25 минут"
        case .pomodoro: "Помодоро"
        case .focus: "Режим фокуса"
        case .coffee: "Кофеин"
        case .keyLock: "Заблокировать клавиатуру на 30 с"
        case .settings: "Настройки Nook"
        case .updates: "Проверить обновления Nook"
        case .thanks: "Сказать спасибо автору Nook"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard.fill"
        case .shelf: "tray.full.fill"
        case .notes: "note.text"
        case .calendar: "calendar"
        case .agents: "sparkles"
        case .timer, .pomodoro: "timer"
        case .focus: "scope"
        case .coffee: "cup.and.saucer.fill"
        case .keyLock: "keyboard"
        case .settings: "gearshape.fill"
        case .updates: "arrow.down.circle.fill"
        case .thanks: "heart.fill"
        }
    }

    var color: Color {
        switch self {
        case .clipboard: Palette.blue
        case .shelf: Palette.cyan
        case .notes: Palette.yellow
        case .calendar: Palette.red
        case .agents: Palette.claude
        case .timer, .pomodoro, .focus: Palette.orange
        case .coffee: Palette.orange
        case .keyLock: Palette.violet
        case .settings: Color(hex: 0x8E8E93)
        case .updates: Palette.green
        case .thanks: Palette.pink
        }
    }

    /// Other words people type for it, English included.
    var aliases: [String] {
        switch self {
        case .clipboard: ["clipboard", "history", "история", "копировать"]
        case .shelf: ["shelf", "files", "файлы", "airdrop"]
        case .notes: ["notes", "заметка"]
        case .calendar: ["calendar", "meeting", "встреча", "события"]
        case .agents: ["agents", "claude", "codex"]
        case .timer: ["timer", "25"]
        case .pomodoro: ["pomodoro", "tomato"]
        case .focus: ["focus", "фокус", "концентрация"]
        case .coffee: ["coffee", "caffeine", "кофе", "не спать", "awake"]
        case .keyLock: ["keyboard", "lock", "клавиатура", "чистка"]
        case .settings: ["settings", "preferences", "параметры", "nook"]
        case .updates: ["update", "обновление", "версия"]
        case .thanks: ["donate", "thanks", "спасибо", "usdt"]
        }
    }
}

/// One thing the search can open.
struct LaunchItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case app(URL)
        case setting(String)
        case nook(NookCommand)
        /// The calculator's answer, always the first row.
        case answer(Calculator.Answer)
        /// A web page or a URL scheme: "github.com", Google, the dictionary.
        case link(URL, symbol: String)
        case window(WindowAction)
        case snippet(Snippet)
        /// An Apple Shortcut by its identifier.
        case shortcut(String)
        case file(URL)
        case emoji(String)
        /// A shell command of the person's own.
        case command(String)
    }

    /// Words to match: folded, with word starts and initials ("Visual Studio Code" → "vsc").
    struct Term: Equatable {
        let text: String
        let words: [String]
        let initials: String

        init(_ raw: String) {
            text = Launcher.fold(raw)
            var parts: [String] = []
            for piece in raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                // "TextEdit" → "Text", "Edit".
                var word = ""
                for character in piece {
                    if character.isUppercase, let last = word.last, last.isLowercase {
                        parts.append(word)
                        word = ""
                    }
                    word.append(character)
                }
                if !word.isEmpty { parts.append(word) }
            }
            words = parts.map(Launcher.fold)
            initials = String(words.compactMap(\.first))
        }
    }

    let id: String
    let title: String
    let subtitle: String
    let terms: [Term]
    let kind: Kind
}

/// Search from the notch (⌥Space or the recorded shortcut): apps, System Settings panes and Nook's own commands.
final class Launcher: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            search()
            files.search(query.trimmingCharacters(in: .whitespaces))
        }
    }
    @Published private(set) var results: [LaunchItem] = []
    @Published var selection = 0
    /// App and pane icons by path, loaded off the main thread.
    @Published private(set) var icons: [String: NSImage] = [:]

    /// Runs a Nook command (set by the model).
    var run: ((NookCommand) -> Void)?
    /// The person's snippets and how to type one into the app in front (set by the model).
    var snippets: () -> [Snippet] = { [] }
    var insertSnippet: ((Snippet) -> Void)?
    /// An island: symbol, title, detail, ok (set by the model).
    var notify: ((String, String, String, Bool) -> Void)?

    private var shortcuts: [LaunchItem] = []
    private var emoji: [Emoji.Entry] = []
    private let files = FileSearch()
    private var fileResults: (query: String, urls: [URL]) = ("", [])
    /// Item ids whose own shortcut another app holds.
    @Published private(set) var takenHotkeys: Set<String> = []
    private var hotkeyIDs: [UInt32] = []

    private var apps: [LaunchItem] = []
    private var panes: [LaunchItem] = []
    private let commands: [LaunchItem] = NookCommand.allCases.map { command in
        LaunchItem(id: "nook:\(command.rawValue)", title: command.title, subtitle: "Nook",
                   terms: ([command.title] + command.aliases).map(LaunchItem.Term.init), kind: .nook(command))
    }
    private let windows: [LaunchItem] = WindowAction.allCases.map { action in
        LaunchItem(id: "window:\(action.rawValue)", title: action.title, subtitle: "Окна",
                   terms: [action.title, action.english, "window", "окно"].map(LaunchItem.Term.init), kind: .window(action))
    }
    private var indexedAt = Date.distantPast
    private var indexing = false
    /// Folders and bundles are read here, never on the main thread.
    private let queue = DispatchQueue(label: "nook.launcher", qos: .userInitiated)

    static let settingsApp = "/System/Applications/System Settings.app"
    static let shortcutsApp = "/System/Applications/Shortcuts.app"

    /// Called when the search opens: a fresh query, and the index again if it is older than a minute.
    func prepare() {
        query = ""
        selection = 0
        Rates.shared.onChange = { [weak self] in self?.search() }
        Rates.shared.refresh()
        search()
        guard !indexing, Date().timeIntervalSince(indexedAt) > 60 else { return }
        indexing = true
        files.onResults = { [weak self] urls in
            guard let self else { return }
            self.fileResults = (self.query.trimmingCharacters(in: .whitespaces), urls)
            self.search()
        }
        queue.async { [weak self] in
            let apps = Self.scanApps()
            let panes = Self.scanPanes()
            let emoji = Emoji.load()
            let shortcuts = Settings.launcherShortcuts ? AppleShortcuts.list().map { shortcut in
                LaunchItem(id: "shortcut:\(shortcut.id)", title: shortcut.name, subtitle: "Быстрая команда",
                           terms: [LaunchItem.Term(shortcut.name)], kind: .shortcut(shortcut.id))
            } : []
            var icons: [String: NSImage] = [:]
            for case .app(let url) in apps.map(\.kind) { icons[url.path] = NSWorkspace.shared.icon(forFile: url.path) }
            icons[Self.settingsApp] = NSWorkspace.shared.icon(forFile: Self.settingsApp)
            icons[Self.shortcutsApp] = NSWorkspace.shared.icon(forFile: Self.shortcutsApp)
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = apps
                self.panes = panes
                self.shortcuts = shortcuts
                self.emoji = emoji
                self.icons = icons
                self.indexedAt = Date()
                self.indexing = false
                self.search()
            }
        }
    }

    /// Apps, panes and commands, for the alias and shortcut list in Settings.
    var everything: [LaunchItem] {
        (apps + panes + shortcuts).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            + commands + windows + customCommands
    }

    func icon(for item: LaunchItem) -> NSImage? {
        switch item.kind {
        case .app(let url): icons[url.path]
        case .setting: icons[Self.settingsApp]
        default: nil
        }
    }

    /// The index for Settings, without touching the query.
    func indexIfNeeded() {
        guard apps.isEmpty else { return }
        let typed = query
        prepare()
        query = typed
    }

    func setAlias(_ alias: String, for id: String) {
        var aliases = Settings.launcherAliases
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        aliases[id] = trimmed.isEmpty ? nil : trimmed
        Settings.launcherAliases = aliases
        search()
    }

    /// "Как в Rectangle": fills in only what has no shortcut yet.
    func useRectangleShortcuts() {
        var keys = Settings.launcherHotkeys
        let used = Set(keys.values.map { $0 })
        for action in WindowAction.allCases {
            let id = "window:\(action.rawValue)"
            guard keys[id] == nil, let shortcut = action.rectangleShortcut else { continue }
            let stored = [Int(shortcut.keyCode), Int(shortcut.modifiers)]
            guard !used.contains(stored) else { continue }
            keys[id] = stored
        }
        Settings.launcherHotkeys = keys
        applyHotkeys()
    }

    func setHotkey(_ shortcut: Shortcut?, for id: String) {
        var keys = Settings.launcherHotkeys
        keys[id] = shortcut.map { [Int($0.keyCode), Int($0.modifiers)] }
        Settings.launcherHotkeys = keys
        applyHotkeys()
    }

    /// While a shortcut is being recorded in Settings: pressing an existing one records instead of opening.
    func pauseHotkeys(_ paused: Bool) {
        if paused {
            hotkeyIDs.forEach(HotKey.unregister)
            hotkeyIDs = []
        } else {
            applyHotkeys()
        }
    }

    /// Carbon hot keys from id 100, one per item that has a shortcut. A shortcut launch is not counted as a visit.
    func applyHotkeys() {
        hotkeyIDs.forEach(HotKey.unregister)
        hotkeyIDs = []
        var taken: Set<String> = []
        var next: UInt32 = 100
        for (id, combo) in Settings.launcherHotkeys.sorted(by: { $0.key < $1.key }) where combo.count == 2 {
            let ok = HotKey.register(id: next, keyCode: UInt32(combo[0]), modifiers: UInt32(combo[1])) { [weak self] in
                self?.launch(id)
            }
            if ok { hotkeyIDs.append(next) } else { taken.insert(id) }
            next += 1
        }
        if takenHotkeys != taken { takenHotkeys = taken }
    }

    private func launch(_ id: String) {
        if let item = (apps + panes + shortcuts + commands + windows + customCommands).first(where: { $0.id == id }) {
            open(item, record: false)
        } else if id.hasPrefix("app:"),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(id.dropFirst(4))) {
            // Pressed before the first index: the bundle id is enough.
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if id.hasPrefix("setting:"), let url = URL(string: "x-apple.systempreferences:\(id.dropFirst(8))") {
            NSWorkspace.shared.open(url)
        }
    }

    private var customCommands: [LaunchItem] {
        Settings.customCommands.compactMap { pair in
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            return LaunchItem(id: "command:\(pair[0])", title: pair[0], subtitle: "Своя команда",
                              terms: [LaunchItem.Term(pair[0])], kind: .command(pair[1]))
        }
    }

    private var pool: [LaunchItem] {
        (Settings.launcherApps ? apps : []) + (Settings.launcherSettings ? panes : [])
            + (Settings.launcherCommands ? commands : []) + (Settings.launcherWindows ? windows : [])
            + (Settings.launcherShortcuts ? shortcuts : []) + customCommands
            + snippets().filter(\.enabled).map { snippet in
                LaunchItem(id: "snippet:\(snippet.file.lastPathComponent)", title: snippet.name,
                           subtitle: snippet.keyword.isEmpty ? "Сниппет" : "Сниппет · \(snippet.keyword)",
                           terms: [snippet.name, snippet.keyword].filter { !$0.isEmpty }.map(LaunchItem.Term.init),
                           kind: .snippet(snippet))
            }
    }

    func search() {
        let usage = Settings.launcherUsage
        let now = Date().timeIntervalSince1970
        func boost(_ id: String) -> Int {
            guard let entry = usage[id], entry.count == 2 else { return 0 }
            let days = max(0, now - entry[1]) / 86_400
            return min(250, Int(entry[0] * 40 / (1 + days / 7)))
        }
        let typed = Self.fold(query.trimmingCharacters(in: .whitespaces))
        // ":heart": emoji only.
        if query.hasPrefix(":") {
            results = Emoji.search(String(query.dropFirst()), in: emoji).prefix(30).map { emoji in
                LaunchItem(id: "emoji:\(emoji.character)", title: emoji.title, subtitle: "Эмодзи",
                           terms: [], kind: .emoji(emoji.character))
            }
            selection = 0
            return
        }
        var found: [(LaunchItem, Int)]
        if typed.isEmpty {
            // Nothing typed: what was opened lately, else Nook's commands.
            found = pool.compactMap { item in boost(item.id) > 0 ? (item, boost(item.id)) : nil }
            if found.isEmpty { found = commands.enumerated().map { ($0.element, -$0.offset) } }
        } else {
            let variants = [(typed, 0), (Self.layout(typed, Self.ruToEn), 60), (Self.layout(typed, Self.enToRu), 60)]
                .filter { $0.0 != typed || $0.1 == 0 }
            let aliases = Settings.launcherAliases.mapValues(Self.fold)
            found = pool.compactMap { item in
                var best: Int?
                // The person's own word wins: exactly, then by its start.
                if let alias = aliases[item.id] {
                    if alias == typed { best = 2000 } else if alias.hasPrefix(typed) { best = 1500 }
                }
                for (variant, penalty) in variants {
                    for term in item.terms {
                        if let score = Self.score(variant, term) { best = max(best ?? .min, score - penalty) }
                    }
                }
                guard let best else { return nil }
                let kind: Int = switch item.kind {
                case .app: 20
                case .nook, .window, .snippet, .shortcut, .command: 10
                case .setting, .answer, .link, .file, .emoji: 0
                }
                return (item, best + kind + boost(item.id))
            }
        }
        var rows = found.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }.prefix(40).map(\.0)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if fileResults.query == trimmed, !trimmed.isEmpty {
            rows += fileResults.urls.map { url in
                LaunchItem(id: "file:\(url.path)", title: url.lastPathComponent,
                           subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                           terms: [], kind: .file(url))
            }
        }
        // "yt котики": a quicklink with what follows its name.
        for link in Settings.quicklinks where link.count == 2 {
            let name = link[0], template = link[1]
            guard trimmed.lowercased().hasPrefix(name.lowercased() + " ") else { continue }
            let argument = String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            guard !argument.isEmpty else { continue }
            let encoded = argument.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? argument
            if let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)) {
                rows.insert(LaunchItem(id: "quicklink:\(name)", title: "\(name): «\(argument)»", subtitle: url.host ?? "Ссылка",
                                       terms: [], kind: .link(url, symbol: "link")), at: 0)
            }
        }
        if let url = Self.webAddress(trimmed) {
            rows.insert(LaunchItem(id: "url", title: "Открыть \(trimmed)", subtitle: "Браузер", terms: [],
                                   kind: .link(url, symbol: "safari.fill")), at: 0)
        }
        if let answer = Calculator.evaluate(query, rates: .shared) {
            rows.insert(LaunchItem(id: "answer", title: answer.result, subtitle: answer.detail, terms: [], kind: .answer(answer)), at: 0)
        }
        if !trimmed.isEmpty, Settings.launcherFallbacks {
            // Always under the results: "Use «query» with…".
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            if let google = URL(string: "https://www.google.com/search?q=\(encoded)") {
                rows.append(LaunchItem(id: "fallback:google", title: "Искать «\(trimmed)» в Google", subtitle: "Интернет",
                                       terms: [], kind: .link(google, symbol: "magnifyingglass")))
            }
            if !trimmed.contains(" "), let word = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let dictionary = URL(string: "dict://\(word)") {
                rows.append(LaunchItem(id: "fallback:dictionary", title: "Определить «\(trimmed)»", subtitle: "Словарь",
                                       terms: [], kind: .link(dictionary, symbol: "character.book.closed.fill")))
            }
        }
        results = rows
        selection = 0
    }

    static func score(_ query: String, _ term: LaunchItem.Term) -> Int? {
        if term.text == query { return 1000 }
        if term.text.hasPrefix(query) { return 900 - min(term.text.count, 60) }
        if let index = term.words.firstIndex(where: { $0.hasPrefix(query) }) { return 800 - index * 10 }
        guard query.count >= 2 else { return nil }
        if term.initials.hasPrefix(query) { return 750 }
        if term.text.contains(query) { return 600 }
        // Letters in order with gaps: "sfr" → "safari".
        var gaps = 0
        var rest = Substring(term.text)
        for character in query {
            guard let at = rest.firstIndex(of: character) else { return nil }
            gaps += rest.distance(from: rest.startIndex, to: at)
            rest = rest[rest.index(after: at)...]
        }
        return max(100, 400 - gaps * 8)
    }

    // MARK: Opening

    /// "github.com", "https://…": a web address, not a search.
    static func webAddress(_ text: String) -> URL? {
        guard !text.contains(" "), text.contains(".") else { return nil }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return URL(string: text) }
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let parts = host.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, (2...12).contains(tld.count), tld.allSatisfy(\.isLetter),
              parts.allSatisfy({ !$0.isEmpty }), Double(text.replacingOccurrences(of: ",", with: ".")) == nil else { return nil }
        return URL(string: "https://" + text)
    }

    func open(_ item: LaunchItem, reveal: Bool = false, record: Bool = true) {
        if case .answer = item.kind { return }
        if case .link(let url, _) = item.kind { NSWorkspace.shared.open(url); return }
        guard record else { return perform(item, reveal: reveal) }
        var usage = Settings.launcherUsage
        let count = usage[item.id]?.first ?? 0
        usage[item.id] = [count + 1, Date().timeIntervalSince1970]
        // Keep the history small: the 300 most recent.
        if usage.count > 300 {
            for key in usage.sorted(by: { $0.value.last ?? 0 < $1.value.last ?? 0 }).prefix(usage.count - 300).map(\.key) {
                usage[key] = nil
            }
        }
        Settings.launcherUsage = usage
        perform(item, reveal: reveal)
    }

    private func perform(_ item: LaunchItem, reveal: Bool) {
        switch item.kind {
        case .app(let url):
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .setting(let id):
            if let url = URL(string: "x-apple.systempreferences:\(id)") { NSWorkspace.shared.open(url) }
        case .nook(let command):
            run?(command)
        case .window(let action):
            WindowManager.shared.perform(action)
        case .snippet(let snippet):
            insertSnippet?(snippet)
        case .shortcut(let id):
            AppleShortcuts.run(id)
        case .file(let url):
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
        case .emoji(let character):
            TextInsertion.type(character)
        case .command(let script):
            let started = Date()
            CustomCommands.run(name: item.title, script: script) { [weak self] ok, text in
                let seconds = Int(Date().timeIntervalSince(started))
                self?.notify?(ok ? "terminal.fill" : "exclamationmark.triangle.fill", item.title,
                              seconds > 1 ? "\(text) · \(seconds) с" : text, ok)
            }
        case .answer, .link:
            break
        }
    }

    func clearHistory() {
        Settings.launcherUsage = [:]
        search()
    }

    // MARK: Index

    /// Apps in the usual folders and one level of subfolders ("/Applications/Adobe …/Photoshop.app").
    private static func scanApps() -> [LaunchItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        // Safari and other cryptex apps: /Applications holds only a hidden link to them.
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "\(home)/Applications",
                     "/System/Library/CoreServices/Applications", "/System/Cryptexes/App/System/Applications"]
        var found: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        for root in roots {
            let url = URL(fileURLWithPath: root, isDirectory: true)
            for entry in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            where !entry.lastPathComponent.hasPrefix(".") {
                if entry.pathExtension == "app" {
                    found.append(entry.resolvingSymlinksInPath())
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    found += ((try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])) ?? [])
                        .filter { $0.pathExtension == "app" }
                }
            }
        }
        var seen = Set<String>()
        var items: [LaunchItem] = []
        for url in found {
            guard let bundle = Bundle(url: url), let info = bundle.infoDictionary,
                  info["LSBackgroundOnly"] as? Bool != true else { continue }
            let id = bundle.bundleIdentifier ?? url.path
            guard id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { continue }
            var local = fm.displayName(atPath: url.path)
            if local.hasSuffix(".app") { local.removeLast(4) }
            let english = (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String
            let names = [local, english, url.deletingPathExtension().lastPathComponent].compactMap { $0 }
            items.append(LaunchItem(id: "app:\(id)", title: local, subtitle: "Программа",
                                    terms: Array(Set(names)).map(LaunchItem.Term.init), kind: .app(url)))
        }
        return items
    }

    /// System Settings panes: the extensions System Settings itself shows, with their names in the system language.
    private static func scanPanes() -> [LaunchItem] {
        let folder = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
        // Names the extension itself does not carry.
        let names = ["com.apple.Battery-Settings.extension": ("Аккумулятор", "Battery")]
        var items: [LaunchItem] = []
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, let info = bundle.infoDictionary,
                  (info["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"] as? String
                    == "com.apple.Settings.extension.ui" else { continue }
            let local = bundle.localizedInfoDictionary ?? [:]
            var title = (local["CFBundleDisplayName"] ?? info["CFBundleDisplayName"]) as? String
            var english = info["CFBundleDisplayName"] as? String
            if let fixed = names[id] { title = fixed.0; english = fixed.1 }
            guard let title, !title.hasSuffix("Extension") else { continue }
            let terms = [title, english].compactMap { $0 }
            items.append(LaunchItem(id: "setting:\(id)", title: title, subtitle: "Системные настройки",
                                    terms: Array(Set(terms)).map(LaunchItem.Term.init), kind: .setting(id)))
        }
        return items
    }

    // MARK: Text

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// "ыфафкш" typed with the Russian layout on → "safari", and back.
    private static let qwerty = Array("qwertyuiop[]asdfghjkl;'zxcvbnm,.`")
    private static let jcuken = Array("йцукенгшщзхъфывапролджэячсмитьбюё")
    static let ruToEn = Dictionary(uniqueKeysWithValues: zip(jcuken, qwerty))
    static let enToRu = Dictionary(uniqueKeysWithValues: zip(qwerty, jcuken))

    static func layout(_ text: String, _ map: [Character: Character]) -> String {
        String(text.map { map[$0] ?? $0 })
    }
}

// MARK: View

struct LauncherTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var launcher: Launcher
    @FocusState private var focused: Bool
    @Namespace private var selectionSpace

    var body: some View {
        let items = launcher.results
        let aliases = Settings.launcherAliases
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(muted)
                TextField("Программы, настройки, команды Nook", text: $launcher.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { open(items, reveal: false) }
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        open(items, reveal: true)
                        return .handled
                    }
                    .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                    // Esc clears the field first, then closes.
                    .onKeyPress(.escape) {
                        if launcher.query.isEmpty { model.collapse() } else { launcher.query = "" }
                        return .handled
                    }
                Text(selectedHint(items)).font(.system(size: 11)).foregroundStyle(faint).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glass(radius: 12)
            .entrance(0)

            if items.isEmpty {
                VStack(spacing: 8) {
                    Badge(symbol: "magnifyingglass", colors: [Palette.blue, Palette.violet], size: 44)
                    Text(launcher.query.isEmpty ? "Начните печатать название программы" : "Ничего не найдено")
                        .font(.system(size: 12)).foregroundStyle(muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ListScroll {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                LaunchRow(item: item, icon: icon(item), alias: aliases[item.id],
                                          selected: index == launcher.selection, selectionSpace: selectionSpace) {
                                    launcher.selection = index
                                    open(items, reveal: false)
                                }
                                .id(item.id)
                            }
                        }
                        .animation(Motion.quick, value: launcher.selection)
                    }
                    .entrance(1)
                    .onChange(of: launcher.selection) { _, new in
                        if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                    }
                }
            }
        }
        .onAppear { if model.sticky && model.panel?.isKeyWindow == true { focused = true } }
    }

    private func icon(_ item: LaunchItem) -> NSImage? {
        switch item.kind {
        case .app(let url): launcher.icons[url.path]
        case .setting: launcher.icons[Launcher.settingsApp]
        case .shortcut: launcher.icons[Launcher.shortcutsApp]
        // By type, not from the file: reading files in Documents could ask for a permission.
        case .file(let url): NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
        case .nook, .answer, .link, .window, .snippet, .emoji, .command: nil
        }
    }

    private func selectedHint(_ items: [LaunchItem]) -> String {
        guard items.indices.contains(launcher.selection) else { return "" }
        switch items[launcher.selection].kind {
        case .app: return "↩ открыть · ⌘↩ в Finder"
        case .snippet, .emoji: return "↩ вставить"
        case .file: return "↩ открыть · ⌘↩ в Finder"
        case .answer(let answer): return answer.isError ? "" : "↩ скопировать · ⌘↩ считать дальше"
        default: return "↩ открыть"
        }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        launcher.selection = min(max(0, launcher.selection + delta), count - 1)
    }

    private func open(_ items: [LaunchItem], reveal: Bool) {
        guard items.indices.contains(launcher.selection) else { return }
        let item = items[launcher.selection]
        if case .answer(let answer) = item.kind {
            guard !answer.isError else { return }
            if reveal {
                // Go on from the answer: "455 UAH", then "* 3".
                launcher.query = answer.chain + " "
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer.copy, forType: .string)
                model.collapse()
                model.show(.copied, for: 1.4)
            }
            return
        }
        if case .emoji = item.kind {
            model.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { launcher.open(item, reveal: false) }
            return
        }
        if case .snippet = item.kind {
            // Into the app the search was opened from.
            model.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { launcher.open(item, reveal: false) }
            return
        }
        if case .window = item.kind {
            // Focus goes back to the window first; then it moves.
            model.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { launcher.open(item, reveal: false) }
            return
        }
        // Nook's commands change the panel themselves; apps and settings take the screen.
        if case .nook = item.kind {
            launcher.open(item, reveal: reveal)
        } else {
            model.collapse(returnFocus: false)
            launcher.open(item, reveal: reveal)
        }
    }
}

struct LaunchRow: View {
    let item: LaunchItem
    let icon: NSImage?
    var alias: String?
    let selected: Bool
    let selectionSpace: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Group {
                if case .answer(let answer) = item.kind { AnswerCard(answer: answer) } else { row }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.clear)
                        .glass(tint: [Palette.blue.opacity(0.28), Palette.violet.opacity(0.1)], radius: 12)
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                } else if hover {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
    }

    private var row: some View {
        HStack(spacing: 10) {
            LaunchIcon(item: item, icon: icon, size: 26)
            Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if let alias { Chip(text: alias, color: .white.opacity(0.75)) }
            Spacer(minLength: 8)
            Text(item.subtitle).font(.system(size: 11)).foregroundStyle(faint).lineLimit(1)
        }
    }
}

/// An app's icon, or a coloured tile with a symbol for Nook's commands and links.
struct LaunchIcon: View {
    let item: LaunchItem
    let icon: NSImage?
    var size: CGFloat = 26

    var body: some View {
        switch item.kind {
        case .nook(let command): tile(command.symbol, command.color)
        case .link(_, let symbol): tile(symbol, Palette.blue)
        case .window(let action): tile(action.symbol, Palette.cyan)
        case .snippet: tile("text.quote", Palette.green)
        case .command: tile("terminal.fill", Color(hex: 0x636366))
        case .emoji(let character): Text(character).font(.system(size: size * 0.78)).frame(width: size, height: size)
        default:
            if let icon {
                Image(nsImage: icon).resizable().frame(width: size, height: size)
            } else {
                Color.clear.frame(width: size, height: size)
            }
        }
    }

    private func tile(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size * 0.92, height: size * 0.92)
            .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(LinearGradient(colors: [color.lifted(), color], startPoint: .top, endPoint: .bottom)))
            .frame(width: size, height: size)
    }
}

/// The calculator's answer: the result large, what it is under it.
struct AnswerCard: View {
    let answer: Calculator.Answer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: answer.isError ? "exclamationmark.triangle.fill" : "equal")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(answer.isError ? Palette.orange : .white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(answer.isError ? Palette.orange.opacity(0.18) : Palette.violet.opacity(0.55)))
            VStack(alignment: .leading, spacing: 1) {
                Text(answer.result)
                    .font(.rounded(answer.isError ? 13 : 17, .semibold))
                    .foregroundStyle(answer.isError ? Palette.orange.lifted() : .white)
                    .lineLimit(1)
                    .textSelection(.enabled)
                if !answer.isError {
                    Text(answer.detail).font(.system(size: 10.5)).foregroundStyle(faint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
