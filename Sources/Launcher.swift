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
    case clipboard, pasteNext, shelf, notes, calendar, agents, timer, pomodoro, focus, coffee, keyLock, settings, updates, thanks

    var title: String {
        switch self {
        case .clipboard: L("Буфер обмена")
        case .pasteNext: L("Вставить следующее из буфера")
        case .shelf: L("Полка")
        case .notes: L("Заметки")
        case .calendar: L("Календарь")
        case .agents: L("Агенты")
        case .timer: L("Таймер на 25 минут")
        case .pomodoro: L("Помодоро")
        case .focus: L("Режим фокуса")
        case .coffee: L("Кофеин")
        case .keyLock: L("Заблокировать клавиатуру на 30 с")
        case .settings: L("Настройки Nook")
        case .updates: L("Проверить обновления Nook")
        case .thanks: L("Сказать спасибо автору Nook")
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: "doc.on.clipboard.fill"
        case .pasteNext: "list.number"
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
        case .clipboard, .pasteNext: Palette.blue
        case .shelf: Palette.cyan
        case .notes: Palette.yellow
        case .calendar: Palette.red
        case .agents: Tone.ink
        case .timer, .pomodoro, .focus: Tone.focus
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
        case .pasteNext: ["paste sequentially", "по очереди", "следующее", "вставить"]
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
        case menu(MenuSearch.Item)
        case openWindow(WindowList.Window)
        /// Ask the assistant this text.
        case ask(String)
        case ai(AIAction)
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
            if answerMode { answerMode = false }
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
    /// Runs an AI action on the selection (set by the model).
    var runAI: ((AIAction) -> Void)?
    /// The panel shows the assistant's answer instead of results.
    @Published var answerMode = false
    /// An island: symbol, title, detail, ok (set by the model).
    var notify: ((String, String, String, Bool) -> Void)?

    private var shortcuts: [LaunchItem] = []
    private var emoji: [Emoji.Entry] = []
    /// Read when the search opens: the front app's menu items and the open windows.
    private var live: [LaunchItem] = []
    /// The open windows read when the search opened (with Accessibility and the setting on).
    var openWindows: [WindowList.Window] { live.compactMap { if case .openWindow(let w) = $0.kind { return w } else { return nil } } }
    private let liveQueue = DispatchQueue(label: "nook.launcher.live", qos: .userInitiated)
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
    private let aiActions: [LaunchItem] = AIAction.allCases.map { action in
        LaunchItem(id: "ai:\(action.rawValue)", title: action.title, subtitle: "AI",
                   terms: [action.title, action.english, "ai"].map(LaunchItem.Term.init), kind: .ai(action))
    }
    private let windows: [LaunchItem] = WindowAction.allCases.map { action in
        LaunchItem(id: "window:\(action.rawValue)", title: action.title, subtitle: L("Окна"),
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
        refreshLive()
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
                LaunchItem(id: "shortcut:\(shortcut.id)", title: shortcut.name, subtitle: L("Быстрая команда"),
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
            + commands + windows + aiActions + customCommands
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
        if let item = (apps + panes + shortcuts + commands + windows + aiActions + customCommands).first(where: { $0.id == id }) {
            open(item, record: false)
        } else if id.hasPrefix("app:"),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: String(id.dropFirst(4))) {
            // Pressed before the first index: the bundle id is enough.
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if id.hasPrefix("setting:"), let url = URL(string: "x-apple.systempreferences:\(id.dropFirst(8))") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshLive() {
        live = []
        guard AXIsProcessTrusted(), Settings.launcherMenus || Settings.launcherOpenWindows else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let frontPID = front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front?.processIdentifier : nil
        let frontName = front?.localizedName ?? ""
        let frontIcon = front?.bundleURL?.path
        liveQueue.async { [weak self] in
            var items: [LaunchItem] = []
            var icons: [String: NSImage] = [:]
            if Settings.launcherMenus, let frontPID {
                for item in MenuSearch.items(of: frontPID) {
                    let path = item.path.joined(separator: " → ")
                    items.append(LaunchItem(id: "menu:\(path)/\(item.title)", title: item.title,
                                            subtitle: [frontName, path, item.keys].filter { !$0.isEmpty }.joined(separator: " · "),
                                            terms: [LaunchItem.Term(item.title), LaunchItem.Term(path + " " + item.title)],
                                            kind: .menu(item)))
                }
                if let frontIcon { icons[frontIcon] = NSWorkspace.shared.icon(forFile: frontIcon) }
            }
            if Settings.launcherOpenWindows {
                for window in WindowList.all() {
                    items.append(LaunchItem(id: "openwindow:\(window.pid)/\(window.title)", title: window.title,
                                            subtitle: L("Окно · \(window.app)") + (window.minimized ? L(" · свёрнуто") : ""),
                                            terms: [LaunchItem.Term(window.title), LaunchItem.Term(window.app)],
                                            kind: .openWindow(window)))
                    if let path = window.bundle?.path, icons[path] == nil { icons[path] = NSWorkspace.shared.icon(forFile: path) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.live = items
                for (path, icon) in icons where self.icons[path] == nil { self.icons[path] = icon }
                self.search()
            }
        }
    }

    private var customCommands: [LaunchItem] {
        Settings.customCommands.compactMap { pair in
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            return LaunchItem(id: "command:\(pair[0])", title: pair[0], subtitle: L("Своя команда"),
                              terms: [LaunchItem.Term(pair[0])], kind: .command(pair[1]))
        }
    }

    private var pool: [LaunchItem] {
        (Settings.launcherApps ? apps : []) + (Settings.launcherSettings ? panes : [])
            + (Settings.launcherCommands ? commands + aiActions : []) + (Settings.launcherWindows ? windows : [])
            + (Settings.launcherShortcuts ? shortcuts : []) + customCommands
            + snippets().filter(\.enabled).map { snippet in
                LaunchItem(id: "snippet:\(snippet.file.lastPathComponent)", title: snippet.name,
                           subtitle: snippet.keyword.isEmpty ? L("Сниппет") : L("Сниппет · \(snippet.keyword)"),
                           terms: [snippet.name, snippet.keyword].filter { !$0.isEmpty }.map(LaunchItem.Term.init),
                           kind: .snippet(snippet))
            }
    }

    /// What you type becomes one value: `rock & roll`, `c++` or `where?` must not split the query or end the path.
    private static let queryValue = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))

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
                LaunchItem(id: "emoji:\(emoji.character)", title: emoji.title, subtitle: L("Эмодзи"),
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
            // Menu items only from two letters: one letter would list half the menu bar.
            found = (pool + (typed.count >= 2 ? live : [])).compactMap { item in
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
                case .nook, .window, .snippet, .shortcut, .command, .ai: 10
                case .setting, .answer, .link, .file, .emoji, .menu, .openWindow, .ask: 0
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
            let encoded = argument.addingPercentEncoding(withAllowedCharacters: Self.queryValue) ?? argument
            if let url = URL(string: template.replacingOccurrences(of: "{query}", with: encoded)) {
                rows.insert(LaunchItem(id: "quicklink:\(name)", title: L("\(name): «\(argument)»"), subtitle: url.host ?? L("Ссылка"),
                                       terms: [], kind: .link(url, symbol: "link")), at: 0)
            }
        }
        if let url = Self.webAddress(trimmed) {
            rows.insert(LaunchItem(id: "url", title: L("Открыть \(trimmed)"), subtitle: L("Браузер"), terms: [],
                                   kind: .link(url, symbol: "safari.fill")), at: 0)
        }
        if let answer = Calculator.evaluate(query, rates: .shared) {
            rows.insert(LaunchItem(id: "answer", title: answer.result, subtitle: answer.detail, terms: [], kind: .answer(answer)), at: 0)
        }
        if !trimmed.isEmpty, rows.first.map({ if case .answer = $0.kind { false } else { true } }) ?? true {
            rows.append(LaunchItem(id: "ask", title: L("Спросить AI: «\(trimmed)»"), subtitle: "Tab", terms: [], kind: .ask(trimmed)))
        }
        if !trimmed.isEmpty, Settings.launcherFallbacks {
            // Always under the results: "Use «query» with…".
            let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: Self.queryValue) ?? trimmed
            if let google = URL(string: "https://www.google.com/search?q=\(encoded)") {
                rows.append(LaunchItem(id: "fallback:google", title: L("Искать «\(trimmed)» в Google"), subtitle: L("Интернет"),
                                       terms: [], kind: .link(google, symbol: "magnifyingglass")))
            }
            if !trimmed.contains(" "), let word = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let dictionary = URL(string: "dict://\(word)") {
                rows.append(LaunchItem(id: "fallback:dictionary", title: L("Определить «\(trimmed)»"), subtitle: L("Словарь"),
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
        case .ai(let action):
            runAI?(action)
        case .ask:
            break
        case .menu(let item):
            MenuSearch.press(item)
        case .openWindow(let window):
            WindowList.raise(window)
        case .command(let script):
            let started = Date()
            CustomCommands.run(name: item.title, script: script) { [weak self] ok, text in
                let seconds = Int(Date().timeIntervalSince(started))
                self?.notify?(ok ? "terminal.fill" : "exclamationmark.triangle.fill", item.title,
                              seconds > 1 ? L("\(text) · \(seconds) с") : text, ok)
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
            items.append(LaunchItem(id: "app:\(id)", title: local, subtitle: L("Программа"),
                                    terms: Array(Set(names)).map(LaunchItem.Term.init), kind: .app(url)))
        }
        return items
    }

    /// System Settings panes: the extensions System Settings itself shows, with their names in the system language.
    private static func scanPanes() -> [LaunchItem] {
        let folder = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true)
        // Names the extension itself does not carry.
        let names = ["com.apple.Battery-Settings.extension": (L("Аккумулятор"), "Battery")]
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
            items.append(LaunchItem(id: "setting:\(id)", title: title, subtitle: L("Системные настройки"),
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

/// Search (Figma «Поиск — раунд 1», B «Главное совпадение»): the field, then the selected result as a card on the
/// left with what Nook knows about it and its keys, and the short list on the right. The calculator and the
/// assistant's answer take the whole width.
struct LauncherTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var launcher: Launcher
    @ObservedObject var assistant: Assistant
    @FocusState private var focused: Bool
    @Namespace private var selectionSpace

    static let heroWidth: CGFloat = 290

    var body: some View {
        let items = launcher.results
        let selected = items.indices.contains(launcher.selection) ? items[launcher.selection] : nil
        VStack(spacing: Spacing.gap) {
            field(items).frame(height: 36).entrance(0)
            Group {
                if launcher.answerMode {
                    answer
                } else if let selected, case .answer(let result) = selected.kind {
                    CalculatorTile(answer: result, query: launcher.query, google: items.first { $0.id == "fallback:google" },
                                   copy: { open(items, reveal: false) }, goOn: { open(items, reveal: true) },
                                   search: { item in model.collapse(returnFocus: false); launcher.open(item) })
                } else if let selected {
                    HStack(alignment: .top, spacing: Spacing.gap) {
                        hero(selected, items: items).frame(width: Self.heroWidth)
                        list(items)
                    }
                } else {
                    nothing
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .entrance(1)
        }
        .onAppear { if model.sticky && model.panel?.isKeyWindow == true { focused = true } }
    }

    // MARK: Field

    private func field(_ items: [LaunchItem]) -> some View {
        HStack(spacing: 10) {
            if launcher.answerMode {
                TileIcon(symbol: "sparkles", color: Tone.meeting, size: 22)
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium)).foregroundStyle(muted)
                    .frame(width: 22)
            }
            TextField("Программы, файлы, команды…", text: $launcher.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit { launcher.answerMode ? copyAnswer() : open(items, reveal: false) }
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    if launcher.answerMode { pasteAnswer() } else { open(items, reveal: true) }
                    return .handled
                }
                // Tab sends what is typed to the assistant.
                .onKeyPress(.tab) {
                    let text = launcher.query.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty { ask(text) }
                    return .handled
                }
                .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                // Esc clears the field first, then closes.
                .onKeyPress(.escape) {
                    if launcher.answerMode {
                        assistant.cancel()
                        launcher.answerMode = false
                    } else if launcher.query.isEmpty {
                        model.collapse()
                    } else {
                        launcher.query = ""
                    }
                    return .handled
                }
            if launcher.answerMode {
                if assistant.working {
                    HStack(spacing: 6) { Spinner(color: Tone.meeting); Text("отвечает…").font(.system(size: 11)).foregroundStyle(faint) }
                }
            } else if !launcher.query.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 6) { KeyCap(text: "Tab"); Text("спросить AI").font(.system(size: 11)).foregroundStyle(faint) }
            }
        }
        .padding(.leading, 7).padding(.trailing, 12)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Surface.tile)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.06))))
    }

    // MARK: Selected result

    private func hero(_ item: LaunchItem, items: [LaunchItem]) -> some View {
        let asks: Bool = if case .ask = item.kind { true } else { false }
        return LaunchHero(item: item, icon: icon(item), alias: Settings.launcherAliases[item.id],
                          keys: Settings.launcherHotkeys[item.id].flatMap(Shortcut.init(stored:))?.title,
                          usage: Settings.launcherUsage[item.id], windows: windows(of: item),
                          recent: launcher.query.trimmingCharacters(in: .whitespaces).isEmpty,
                          nothingFound: asks && !hasMatches(items),
                          primary: { open(items, reveal: false) }, reveal: { open(items, reveal: true) })
    }

    /// The app's open windows, read when the search opened (Accessibility).
    private func windows(of item: LaunchItem) -> [String] {
        guard case .app(let url) = item.kind else { return [] }
        return launcher.openWindows.filter { $0.bundle?.standardizedFileURL == url.standardizedFileURL }
            .map(\.title).filter { !$0.isEmpty }
    }

    /// Something matched besides asking the assistant and the web fallbacks.
    private func hasMatches(_ items: [LaunchItem]) -> Bool {
        items.contains { item in
            if case .ask = item.kind { return false }
            return !item.id.hasPrefix("fallback:")
        }
    }

    // MARK: List

    private func list(_ items: [LaunchItem]) -> some View {
        let recent = launcher.query.trimmingCharacters(in: .whitespaces).isEmpty
        let aliases = Settings.launcherAliases
        let usage = Settings.launcherUsage
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        LaunchRow(item: item, icon: icon(item), alias: aliases[item.id],
                                  trailing: recent ? usage[item.id].flatMap(LaunchHero.ago) : nil,
                                  keys: Settings.launcherHotkeys[item.id].flatMap(Shortcut.init(stored:))?.title,
                                  selected: index == launcher.selection, selectionSpace: selectionSpace) {
                            launcher.selection = index
                            open(items, reveal: false)
                        }
                        .id(item.id)
                    }
                    if !recent && !hasMatches(items) {
                        VStack(alignment: .leading, spacing: 6) {
                            Caps(text: L("Ничего не найдено"), color: faint)
                            Text("Проверено: программы, настройки, команды, окна, меню, файлы, сниппеты.")
                                .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.top, 12)
                    }
                }
                .animation(Motion.quick, value: launcher.selection)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: launcher.selection) { _, new in
                if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
            }
        }
    }

    private var nothing: some View {
        Tile {
            VStack(spacing: 8) {
                TileIcon(symbol: "magnifyingglass", color: Tone.info, size: 40)
                Text(launcher.query.isEmpty ? L("Начните печатать название программы") : L("Ничего не найдено"))
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Assistant

    private var answer: some View {
        HStack(alignment: .top, spacing: Spacing.gap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) { TileIcon(symbol: "sparkles", color: Tone.meeting, size: 20); Caps(text: L("Вопрос")) }
                Text(assistant.question).font(.system(size: 16, weight: .bold)).lineLimit(3).padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Settings.aiProvider.title.components(separatedBy: " (").first ?? "")
                    .font(.system(size: 11.5)).foregroundStyle(muted).padding(.top, 6)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Button { copyAnswer() } label: { PillKeys(title: L("Скопировать"), keys: "↩") }
                        .buttonStyle(.pill(.primary, small: true)).disabled(assistant.answer.isEmpty)
                    Button { pasteAnswer() } label: { PillKeys(title: L("Вставить"), keys: "⌘↩") }
                        .buttonStyle(.pill(.ghost, small: true)).disabled(assistant.answer.isEmpty)
                    Spacer(minLength: 0)
                    HStack(spacing: 5) { KeyCap(text: "Esc"); Text("назад").font(.system(size: 11)).foregroundStyle(faint) }
                }
            }
            .padding(Spacing.pad)
            .frame(width: Self.heroWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .tile(.accent(Tone.meeting))
            AnswerPanel(assistant: assistant)
        }
    }

    private func ask(_ question: String) {
        guard assistant.isReady else {
            model.collapse()
            model.onOpenSettings?(.ai)
            return
        }
        launcher.answerMode = true
        assistant.ask(question)
    }

    private func copyAnswer() {
        guard !assistant.answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(assistant.answer, forType: .string)
        model.collapse()
        model.show(.copied, for: 1.4)
    }

    private func pasteAnswer() {
        let text = assistant.answer
        guard !text.isEmpty else { return }
        model.collapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { TextInsertion.paste(text) }
    }

    private func icon(_ item: LaunchItem) -> NSImage? {
        switch item.kind {
        case .app(let url): launcher.icons[url.path]
        case .setting: launcher.icons[Launcher.settingsApp]
        case .shortcut: launcher.icons[Launcher.shortcutsApp]
        // By type, not from the file: reading files in Documents could ask for a permission.
        case .file(let url): NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
        case .openWindow(let window): window.bundle.flatMap { launcher.icons[$0.path] }
        case .menu: NSWorkspace.shared.frontmostApplication?.bundleURL.flatMap { launcher.icons[$0.path] }
        case .nook, .answer, .link, .window, .snippet, .emoji, .command, .ask, .ai: nil
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
        if case .ask(let question) = item.kind {
            ask(question)
            return
        }
        if case .ai = item.kind {
            // The model reads the selection of the app the search was opened from.
            launcher.open(item, reveal: false)
            return
        }
        if case .menu = item.kind {
            // The app must be in front for its menu to act.
            model.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { launcher.open(item, reveal: false) }
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

/// One result in the list: icon, title (and its own word), what it is or when it was opened, its keys.
struct LaunchRow: View {
    let item: LaunchItem
    let icon: NSImage?
    var alias: String?
    /// "3 мин" for what was opened lately; else what kind of thing it is.
    var trailing: String?
    var keys: String?
    let selected: Bool
    let selectionSpace: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LaunchIcon(item: item, icon: icon, size: 20)
                Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let alias { Chip(text: alias, color: .white.opacity(0.75)) }
                Spacer(minLength: 8)
                if let keys { KeyCap(text: keys) } else {
                    Text(trailing ?? item.subtitle).font(.system(size: 11)).foregroundStyle(faint).lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if selected {
                    shape.fill(Surface.raised)
                        .overlay(shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5))
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                } else if hover {
                    shape.fill(Color.white.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
    }
}

/// The selected result, large: what it is and where, the person's own word and keys, how often it was opened, the
/// app's open windows; its actions with their keys.
struct LaunchHero: View {
    let item: LaunchItem
    let icon: NSImage?
    let alias: String?
    let keys: String?
    /// [count, last opened (seconds since 1970)] from `Settings.launcherUsage`.
    let usage: [Double]?
    let windows: [String]
    /// Nothing typed: the list is what was opened lately.
    let recent: Bool
    /// Only the assistant and the web are left for this query.
    let nothingFound: Bool
    let primary: () -> Void
    let reveal: () -> Void

    /// "сейчас", "3 мин", "2 ч", "вчера", "5 дн".
    static func ago(_ entry: [Double]) -> String? {
        guard entry.count == 2 else { return nil }
        let seconds = max(0, Date().timeIntervalSince1970 - entry[1])
        if seconds < 60 { return L("сейчас") }
        if seconds < 3600 { return L("\(Int(seconds / 60)) мин") }
        if seconds < 86_400 { return L("\(Int(seconds / 3600)) ч") }
        if seconds < 2 * 86_400 { return L("вчера") }
        return L("\(Int(seconds / 86_400)) дн")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if case .ask = item.kind {
                    TileIcon(symbol: "sparkles", color: Tone.meeting, size: 32)
                } else {
                    LaunchIcon(item: item, icon: icon, size: 44)
                }
                Spacer(minLength: 8)
                if let keys {
                    KeyCap(text: keys)
                } else if case .ask = item.kind {
                    KeyCap(text: "Tab")
                } else if recent, let usage, let when = Self.ago(usage) {
                    Text(when == L("сейчас") ? when : when + L(" назад")).font(.system(size: 11)).foregroundStyle(faint)
                }
            }
            Text(title).font(.system(size: 22, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7).padding(.top, 10)
            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(muted).lineLimit(nothingFound ? 3 : 1)
                .truncationMode(.middle).padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) { facts }.padding(.top, 10)
            Spacer(minLength: 0)
            actions
        }
        .padding(Spacing.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile(isAsk ? .accent(Tone.meeting) : .plain)
    }

    private var isAsk: Bool { if case .ask = item.kind { true } else { false } }

    private var title: String {
        if case .ask = item.kind { return L("Спросить AI") }
        return item.title
    }

    private var subtitle: String {
        switch item.kind {
        case .ask(let question):
            return "«\(question)»" + (nothingFound ? "\n" + L("Среди программ, файлов и меню ничего — даже в другой раскладке.") : "")
        case .app(let url):
            // System apps live in a sealed volume ("/System/Cryptexes/App/System/Applications"): say what that is.
            let folder = url.deletingLastPathComponent().path
            return L("Программа · ") + (folder.hasPrefix("/System") ? L("встроенная в macOS") : (folder as NSString).abbreviatingWithTildeInPath)
        case .file(let url):
            return (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        default:
            return item.subtitle
        }
    }

    /// Two lines at most: they share the tile with the actions.
    @ViewBuilder private var facts: some View {
        if !windows.isEmpty {
            Caps(text: L("Открытые окна"), color: faint)
            ForEach(windows.prefix(alias == nil ? 2 : 1), id: \.self) { title in
                HStack(spacing: 7) {
                    Image(systemName: "macwindow").font(.system(size: 10.5)).foregroundStyle(muted)
                    Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            }
        } else if let usage, usage.count == 2, !isAsk {
            let times = Int(usage[0])
            HStack(spacing: 8) {
                Caps(text: L("Открывали"), color: faint)
                Text(Format.count(times, "раз", "раза", "раз") + " · " + Format.when(Date(timeIntervalSince1970: usage[1])))
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
        }
        if let alias {
            HStack(spacing: 8) { Caps(text: L("Сокращение"), color: faint); Chip(text: alias, color: .white.opacity(0.75)) }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            Button(action: primary) { PillKeys(title: primaryTitle, keys: "↩") }.buttonStyle(.pill(.primary, small: true))
            switch item.kind {
            case .app, .file:
                Button(action: reveal) { PillKeys(title: L("В Finder"), keys: "⌘↩") }.buttonStyle(.pill(.ghost, small: true))
            default:
                EmptyView()
            }
        }
    }

    private var primaryTitle: String {
        switch item.kind {
        case .ask: L("Спросить")
        case .snippet, .emoji: L("Вставить")
        case .menu, .ai, .nook, .command, .shortcut, .window: L("Выполнить")
        case .openWindow: L("Перейти")
        default: L("Открыть")
        }
    }
}

/// A key or a combination on a small cap: "Tab", "⌥⌘P".
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            .padding(.horizontal, 6).frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.1))))
    }
}

/// A pill's label with its key after it: "Открыть ↩".
struct PillKeys: View {
    let title: String
    let keys: String
    var body: some View {
        HStack(spacing: 6) { Text(title); Text(keys).opacity(0.5) }
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
        case .ai(let action): tile(action.symbol, Palette.violet)
        case .ask: tile("sparkles", Palette.violet)
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

/// The assistant's answer as it streams in, in a tile beside the question.
struct AnswerPanel: View {
    @ObservedObject var assistant: Assistant

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(showsIndicators: false) {
                Text(rendered)
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            if let failure = assistant.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(Tone.deny)
            }
        }
        .padding(Spacing.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
    }

    /// Bold, italics and code from Markdown; line breaks kept.
    private var rendered: AttributedString {
        let text = assistant.answer.isEmpty ? (assistant.working ? L("Думаю…") : "") : assistant.answer
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// The calculator's answer across the whole width: the result large, what it is, copy or go on from it.
struct CalculatorTile: View {
    let answer: Calculator.Answer
    let query: String
    let google: LaunchItem?
    let copy: () -> Void
    let goOn: () -> Void
    let search: (LaunchItem) -> Void

    var body: some View {
        let (number, unit) = Self.split(answer.result)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                TileIcon(symbol: answer.isError ? "exclamationmark.triangle.fill" : "equal", color: answer.isError ? Tone.deny : Tone.ink, size: 20)
                Caps(text: L("Калькулятор"))
                Spacer(minLength: 8)
                if !answer.isError { Text(answer.detail).font(.system(size: 11)).foregroundStyle(faint).lineLimit(1) }
            }
            Text(query.trimmingCharacters(in: .whitespaces) + " →").font(.system(size: 15, weight: .medium)).foregroundStyle(muted)
                .lineLimit(1).padding(.top, 14)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(number).font(.rounded(answer.isError ? 22 : 64, .heavy))
                    .foregroundStyle(answer.isError ? Tone.deny : .white)
                    .lineLimit(1).minimumScaleFactor(0.4).textSelection(.enabled)
                if let unit { Text(unit).font(.rounded(28, .heavy)).foregroundStyle(.white.opacity(0.5)) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if !answer.isError {
                    Button(action: copy) { PillKeys(title: L("Скопировать"), keys: "↩") }.buttonStyle(.pill(.primary, small: true))
                    Button(action: goOn) { PillKeys(title: L("Считать дальше"), keys: "⌘↩") }.buttonStyle(.pill(.ghost, small: true))
                }
                Spacer(minLength: 0)
                if let google {
                    Button { search(google) } label: {
                        HStack(spacing: 6) { Image(systemName: "globe").foregroundStyle(Tone.limit); Text("Искать в Google") }
                    }
                    .buttonStyle(.pill(.ghost, small: true))
                }
            }
        }
        .padding(Spacing.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tile()
    }

    /// "5 784,00 UAH" → number and unit; a result without letters at its end stays whole.
    static func split(_ result: String) -> (String, String?) {
        let parts = result.split(separator: " ")
        guard parts.count > 1, let last = parts.last, last.allSatisfy(\.isLetter) else { return (result, nil) }
        return (parts.dropLast().joined(separator: " "), String(last))
    }
}
