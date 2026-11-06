import AppKit
import SwiftUI

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
    @Published var query = "" { didSet { if query != oldValue { search() } } }
    @Published private(set) var results: [LaunchItem] = []
    @Published var selection = 0
    /// App and pane icons by path, loaded off the main thread.
    @Published private(set) var icons: [String: NSImage] = [:]

    /// Runs a Nook command (set by the model).
    var run: ((NookCommand) -> Void)?

    private var apps: [LaunchItem] = []
    private var panes: [LaunchItem] = []
    private let commands: [LaunchItem] = NookCommand.allCases.map { command in
        LaunchItem(id: "nook:\(command.rawValue)", title: command.title, subtitle: "Nook",
                   terms: ([command.title] + command.aliases).map(LaunchItem.Term.init), kind: .nook(command))
    }
    private var indexedAt = Date.distantPast
    private var indexing = false
    /// Folders and bundles are read here, never on the main thread.
    private let queue = DispatchQueue(label: "nook.launcher", qos: .userInitiated)

    static let settingsApp = "/System/Applications/System Settings.app"

    /// Called when the search opens: a fresh query, and the index again if it is older than a minute.
    func prepare() {
        query = ""
        selection = 0
        search()
        guard !indexing, Date().timeIntervalSince(indexedAt) > 60 else { return }
        indexing = true
        queue.async { [weak self] in
            let apps = Self.scanApps()
            let panes = Self.scanPanes()
            var icons: [String: NSImage] = [:]
            for case .app(let url) in apps.map(\.kind) { icons[url.path] = NSWorkspace.shared.icon(forFile: url.path) }
            icons[Self.settingsApp] = NSWorkspace.shared.icon(forFile: Self.settingsApp)
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = apps
                self.panes = panes
                self.icons = icons
                self.indexedAt = Date()
                self.indexing = false
                self.search()
            }
        }
    }

    private var pool: [LaunchItem] {
        (Settings.launcherApps ? apps : []) + (Settings.launcherSettings ? panes : [])
            + (Settings.launcherCommands ? commands : [])
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
        var found: [(LaunchItem, Int)]
        if typed.isEmpty {
            // Nothing typed: what was opened lately, else Nook's commands.
            found = pool.compactMap { item in boost(item.id) > 0 ? (item, boost(item.id)) : nil }
            if found.isEmpty { found = commands.enumerated().map { ($0.element, -$0.offset) } }
        } else {
            let variants = [(typed, 0), (Self.layout(typed, Self.ruToEn), 60), (Self.layout(typed, Self.enToRu), 60)]
                .filter { $0.0 != typed || $0.1 == 0 }
            found = pool.compactMap { item in
                var best: Int?
                for (variant, penalty) in variants {
                    for term in item.terms {
                        if let score = Self.score(variant, term) { best = max(best ?? .min, score - penalty) }
                    }
                }
                guard let best else { return nil }
                let kind: Int = switch item.kind {
                case .app: 20
                case .nook: 10
                case .setting: 0
                }
                return (item, best + kind + boost(item.id))
            }
        }
        results = found.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }.prefix(40).map(\.0)
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

    func open(_ item: LaunchItem, reveal: Bool = false) {
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
                    .onKeyPress(.escape) { model.collapse(); return .handled }
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
                                LaunchRow(item: item, icon: icon(item), selected: index == launcher.selection,
                                          selectionSpace: selectionSpace) {
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
        case .nook: nil
        }
    }

    private func selectedHint(_ items: [LaunchItem]) -> String {
        guard items.indices.contains(launcher.selection) else { return "" }
        if case .app = items[launcher.selection].kind { return "↩ открыть · ⌘↩ в Finder" }
        return "↩ открыть"
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        launcher.selection = min(max(0, launcher.selection + delta), count - 1)
    }

    private func open(_ items: [LaunchItem], reveal: Bool) {
        guard items.indices.contains(launcher.selection) else { return }
        let item = items[launcher.selection]
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
    let selected: Bool
    let selectionSpace: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if case .nook(let command) = item.kind {
                    Image(systemName: command.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(LinearGradient(colors: [command.color.lifted(), command.color], startPoint: .top, endPoint: .bottom)))
                } else if let icon {
                    Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
                Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(faint).lineLimit(1)
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
}
