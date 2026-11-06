import AppKit
import AVFoundation
import Combine
import CoreImage
import Security
import SwiftUI

/// Sections of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, panel, launcher, snippets, clipboard, ai, notch, notifications, dictation, agents, privacy, updates, thanks

    var id: String { rawValue }
    /// The first group in the sidebar: what Nook does. The second one is about Nook itself.
    static let settings: [SettingsPane] = [.general, .panel, .launcher, .snippets, .clipboard, .ai, .notch, .notifications, .dictation, .agents, .privacy]
    static let about: [SettingsPane] = [.updates, .thanks]

    var title: String {
        switch self {
        case .general: L("Основные")
        case .panel: L("Панель")
        case .launcher: L("Поиск")
        case .snippets: L("Сниппеты")
        case .clipboard: L("Буфер обмена")
        case .ai: "AI"
        case .notch: L("Вырез")
        case .notifications: L("Уведомления")
        case .dictation: L("Диктовка")
        case .agents: L("Агенты")
        case .privacy: L("Приватность")
        case .updates: L("Обновления")
        case .thanks: L("Спасибо автору")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .panel: "rectangle.3.group.fill"
        case .launcher: "magnifyingglass"
        case .snippets: "text.quote"
        case .clipboard: "doc.on.clipboard.fill"
        case .ai: "sparkles"
        case .notch: "rectangle.topthird.inset.filled"
        case .notifications: "bell.badge.fill"
        case .dictation: "waveform"
        case .agents: "sparkles"
        case .privacy: "hand.raised.fill"
        case .updates: "arrow.down.circle.fill"
        case .thanks: "heart.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: Color(hex: 0x8E8E93)
        case .panel: Palette.yellow
        case .launcher: Palette.cyan
        case .snippets: Palette.green
        case .clipboard: Palette.blue
        case .ai: Palette.violet
        case .notch: Palette.orange
        case .notifications: Palette.red
        case .dictation: Palette.violet
        case .agents: Palette.claude
        case .privacy: Palette.blue
        case .updates: Palette.green
        case .thanks: Palette.pink
        }
    }
}

// MARK: Window

/// Nook's settings in a normal window. Opened from the gear in the panel, the menu bar icon or
/// `Nook --show settings[:pane]`.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let state: SettingsState
    private var window: NSWindow?
    /// The app the person was in before: it gets the keyboard back when the window closes.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(state: SettingsState) {
        self.state = state
    }

    func show(_ pane: SettingsPane? = nil) {
        if let pane { state.pane = pane }
        let window = self.window ?? makeWindow()
        self.window = window
        if activationObserver == nil {
            remember(NSWorkspace.shared.frontmostApplication)
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                self?.remember(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
        }
        state.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApp = app
    }

    private func makeWindow() -> NSWindow {
        let window = SettingsNSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.title = L("Настройки Nook")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        let host = NSHostingController(rootView: SettingsView(state: state, agents: state.model.agents))
        host.sizingOptions = [.minSize]
        window.contentViewController = host
        window.setContentSize(NSSize(width: 780, height: 560))
        window.center()
        window.setFrameAutosaveName("NookSettings")
        window.delegate = self
        return window
    }

    /// Back from System Settings: a permission may have changed.
    func windowDidBecomeKey(_ notification: Notification) { state.refresh() }

    func windowWillClose(_ notification: Notification) {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        // An accessory app without a window would keep the keyboard: typing would go nowhere.
        if NSApp.isActive, let previousApp, !previousApp.isTerminated { previousApp.activate() }
        previousApp = nil
    }
}

private final class SettingsNSWindow: NSWindow {
    /// Nook has no main menu (accessory app), so ⌘W is handled here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: State

/// What the Settings window shows. Switches that only store a value write `Settings` directly;
/// everything with a side effect (panel, menu bar icon, files) goes through here.
final class SettingsState: ObservableObject {
    struct Note: Equatable {
        var ok: Bool
        var text: String
    }

    struct NamedApp: Identifiable, Equatable {
        var id: String
        var name: String
    }

    @Published var pane: SettingsPane = .general
    @Published private(set) var accessibility = AXIsProcessTrusted()
    @Published private(set) var fullDiskAccess = false
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var loginItem = false
    @Published private(set) var shellConnected = false
    @Published private(set) var mutedApps: [NamedApp] = []
    @Published private(set) var signature: Signature?
    @Published private(set) var checking = false
    @Published private(set) var launcherKeyTaken = false
    @Published private(set) var updateText = ""
    @Published private(set) var checkedAt: Date?
    @Published var agentsNote: Note?
    @Published var shellNote: Note?

    let model: NotchModel
    weak var app: AppDelegate?
    /// Files are read here, never on the main thread: a first-time permission prompt would block it.
    private let io = DispatchQueue(label: "nook.settings")
    private var bag = Set<AnyCancellable>()

    init(model: NotchModel, app: AppDelegate) {
        self.model = model
        self.app = app
        // Full Disk Access: whether the notification database opens (TCC.db stays closed even with it on macOS 27).
        model.notifications.$hasAccess.removeDuplicates().sink { [weak self] in self?.fullDiskAccess = $0 }.store(in: &bag)
    }

    /// A binding to a stored value; the window redraws when it changes.
    func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { [weak self] value in
            self?.objectWillChange.send()
            set(value)
        })
    }

    /// Reads permissions and files again (window opened or back in front).
    func refresh() {
        objectWillChange.send()
        accessibility = AXIsProcessTrusted()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        model.dictation.apply()
        if !checking { updateText = model.updater.status }
        model.agents.checkHooks()
        let shellScript = AgentHub.shellScriptURL.path
        let muted = Settings.mutedApps
        io.async { [weak self] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let zshrc = (try? String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)) ?? ""
            let login = LoginItem.isEnabled
            let apps = muted.map { NamedApp(id: $0, name: Self.appName($0)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let signature = Signature.current
            DispatchQueue.main.async {
                guard let self else { return }
                if self.shellConnected != zshrc.contains(shellScript) { self.shellConnected = zshrc.contains(shellScript) }
                if self.loginItem != login { self.loginItem = login }
                if self.mutedApps != apps { self.mutedApps = apps }
                if self.signature == nil { self.signature = signature }
            }
        }
    }

    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    // General

    func setLoginItem(_ on: Bool) {
        LoginItem.setEnabled(on)
        loginItem = on
    }

    func setMenuIcon(_ on: Bool) {
        objectWillChange.send()
        app?.setMenuIcon(on)
    }

    func chooseScreen(_ id: String?) {
        objectWillChange.send()
        app?.chooseScreen(id)
    }

    // Privacy

    func setHideFromCapture(_ on: Bool) {
        objectWillChange.send()
        Settings.hideFromCapture = on
        model.panel?.sharingType = on ? .none : .readOnly
    }

    /// Puts Nook into the Accessibility list (with the system prompt) and opens that list.
    func askAccessibility() {
        model.volume.askAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openFullDiskAccess() { NotificationWatcher.openSettings() }

    func showData() { NSWorkspace.shared.activateFileViewerSelecting([supportDir]) }

    func unmute(_ bundleID: String?) {
        if let bundleID { Settings.mutedApps.remove(bundleID) } else { Settings.mutedApps = [] }
        mutedApps.removeAll { bundleID == nil || $0.id == bundleID }
    }

    func unignore(_ name: String?) {
        objectWillChange.send()
        if let name { Settings.ignoredProcesses.remove(name) } else { Settings.ignoredProcesses = [] }
    }

    // Agents

    func connectAgents() {
        agentsNote = nil
        io.async { [weak self] in
            let result = AgentHub.installHooks()
            DispatchQueue.main.async {
                self?.agentsNote = Note(ok: result.ok, text: result.message)
                self?.model.agents.checkHooks()
            }
        }
    }

    func connectShell() {
        shellNote = nil
        io.async { [weak self] in
            let result = AgentHub.installShellIntegration()
            DispatchQueue.main.async {
                self?.shellNote = Note(ok: result.ok, text: result.message)
                if result.ok { self?.shellConnected = true }
            }
        }
    }

    // Panel

    /// A tab or header button on or off; the notch redraws at once.
    func setShown(_ id: String, _ shown: Bool) {
        objectWillChange.send()
        var hidden = Settings.headerHidden
        if shown { hidden.remove(id) } else { hidden.insert(id) }
        Settings.headerHidden = hidden
        model.objectWillChange.send()
    }

    // Search

    func setLauncher(_ on: Bool) {
        objectWillChange.send()
        Settings.launcher = on
        launcherKeyTaken = !(app?.applyLauncherHotKey() ?? true)
    }

    func setLauncherShortcut(_ shortcut: Shortcut) {
        objectWillChange.send()
        Settings.launcherShortcut = shortcut
        launcherKeyTaken = !(app?.applyLauncherHotKey() ?? true)
    }

    func recordingLauncherShortcut(_ recording: Bool) {
        launcherKeyTaken = !(app?.applyLauncherHotKey(paused: recording) ?? true)
    }

    func setDictationShortcut(_ shortcut: Shortcut) {
        objectWillChange.send()
        Settings.dictationShortcut = shortcut
        model.dictation.apply()
    }

    // Dictation

    func setDictation(_ on: Bool) {
        objectWillChange.send()
        Settings.dictation = on
        model.dictation.apply()
        guard on else { return }
        if !AXIsProcessTrusted() { askAccessibility() }
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.microphone = AVCaptureDevice.authorizationStatus(for: .audio) }
            }
        }
    }

    func openMicrophone() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    // Updates

    func checkUpdates() {
        guard !checking else { return }
        checking = true
        model.updater.check(manual: true) { [weak self] text in
            guard let self else { return }
            self.checking = false
            self.updateText = text
            self.checkedAt = Date()
        }
    }
}

/// Who signed the running copy: shown under Updates, because updates accept only builds signed by Nook.
struct Signature: Equatable {
    enum Kind { case developerID, local, other, adHoc }
    var kind: Kind
    /// "Oleh Yaitsov" for Developer ID, the certificate name otherwise.
    var name: String
    var notarized: Bool

    static let current: Signature = {
        var me: SecCode?
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let leaf = ((info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        else { return Signature(kind: .adHoc, name: "", notarized: false) }
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? ""
        var requirement: SecRequirement?
        let notarized = SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess
            && requirement.map { SecStaticCodeCheckValidity(code, [], $0) == errSecSuccess } == true
        let prefix = "Developer ID Application: "
        if subject.hasPrefix(prefix) {
            // "Developer ID Application: Oleh Yaitsov (T2KMY2TV9W)" → "Oleh Yaitsov".
            var name = String(subject.dropFirst(prefix.count))
            if let team = name.range(of: " (", options: .backwards) { name = String(name[..<team.lowerBound]) }
            return Signature(kind: .developerID, name: name, notarized: notarized)
        }
        return Signature(kind: subject == "Nook Local Signing" ? .local : .other, name: subject, notarized: notarized)
    }()

    var title: String {
        switch kind {
        case .developerID: "Developer ID · \(name)"
        case .local: L("Локальный сертификат Nook")
        case .other: name
        case .adHoc: L("Без постоянной подписи")
        }
    }

    var explanation: String {
        switch kind {
        case .developerID where notarized:
            L("Подписано сертификатом разработчика и проверено Apple: macOS открывает Nook без предупреждений.")
        case .developerID:
            L("Подписано сертификатом разработчика. Эту сборку Apple ещё не проверяла (нотаризация), её собрали на этом Mac.")
        case .local:
            L("Подписано сертификатом «Nook Local Signing». macOS сохраняет разрешения между сборками.")
        case .other:
            L("Обновление установится, только если оно подписано так же, как эта копия.")
        case .adHoc:
            L("Сборка без сертификата: macOS будет заново спрашивать разрешения, а обновления с GitHub не установятся.")
        }
    }
}

// MARK: Root view

struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var agents: AgentHub

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { state.pane }, set: { if let pane = $0 { state.pane = pane } })) {
                Section {
                    ForEach(SettingsPane.settings) { row($0) }
                }
                Section("Nook") {
                    ForEach(SettingsPane.about) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 210, max: 210)
            .safeAreaInset(edge: .bottom) {
                Text("Nook \(Updater.version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        } detail: {
            Group {
                switch state.pane {
                case .general: GeneralPane(state: state)
                case .panel: PanelPane(state: state)
                case .launcher: LauncherPane(state: state)
                case .snippets: SnippetsPane(state: state, snippets: state.model.snippets)
                case .clipboard: ClipboardPane(state: state)
                case .ai: AIPane(assistant: state.model.assistant)
                case .notch: NotchPane(state: state)
                case .notifications: NotificationsPane(state: state)
                case .dictation: DictationPane(state: state, dictation: state.model.dictation)
                case .agents: AgentsPane(state: state, agents: agents)
                case .privacy: PrivacyPane(state: state)
                case .updates: UpdatesPane(state: state)
                case .thanks: ThanksPane()
                }
            }
            .formStyle(.grouped)
            .id(state.pane)
            .navigationTitle(state.pane.title)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private func row(_ pane: SettingsPane) -> some View {
        Label { Text(pane.title) } icon: { PaneIcon(pane: pane) }
            .tag(pane)
    }
}

// MARK: Building blocks

/// Coloured rounded tile with a white symbol, like System Settings.
struct PaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [pane.color.lifted(), pane.color], startPoint: .top, endPoint: .bottom)))
    }
}

/// "● Разрешено" in green or "● Нет доступа" in orange.
struct StatusText: View {
    let ok: Bool
    let yes: String
    let no: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(ok ? yes : no).foregroundStyle(.secondary)
        }
    }
}

/// Result of an action (connecting agents, zsh) under its row.
struct NoteText: View {
    let note: SettingsState.Note

    var body: some View {
        Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(note.ok ? Color.secondary : Color.orange)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Panes

struct GeneralPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            LanguageSection()
            Section {
                Toggle("Запускать при входе в систему", isOn: state.bind({ state.loginItem }, state.setLoginItem))
                Toggle("Значок в строке меню", isOn: state.bind({ Settings.showMenuIcon }, state.setMenuIcon))
            } header: {
                Text("Запуск")
            }
            Section {
                Picker("Вырез на экране", selection: state.bind({ Settings.screenID }, state.chooseScreen)) {
                    Text(NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } ? L("Автоматически (экран с вырезом)") : L("Автоматически"))
                        .tag(String?.none)
                    Divider()
                    ForEach(NSScreen.screens, id: \.self) { screen in
                        if let id = NotchGeometry.uuid(of: screen) {
                            Text(screen.localizedName).tag(Optional(id))
                        }
                    }
                }
            } header: {
                Text("Экран")
            }
            Section("Быстрый доступ") {
                LabeledContent("Поиск") { Text(Settings.launcherShortcut.title).font(.system(size: 12, weight: .medium, design: .rounded)) }
                LabeledContent("Буфер обмена") { Text("⌃⌘V").font(.system(size: 12, weight: .medium, design: .rounded)) }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Выйти из Nook") { NSApp.terminate(nil) }
                }
            }
        }
    }
}

/// The interface language; a new one needs a restart (macOS picks the language when an app starts).
struct LanguageSection: View {
    @State private var choice = Language.chosen

    var body: some View {
        Section {
            Picker("Язык", selection: Binding(get: { choice }, set: { choice = $0; Language.chosen = $0 })) {
                ForEach(Language.allCases) { Text($0.title).tag($0) }
            }
            if choice.resolved != Language.shown {
                LabeledContent("Язык сменится после перезапуска") {
                    Button("Перезапустить Nook") { Language.restartNook() }
                }
            }
        }
    }
}

struct PanelPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        let shownTabs = Tab.buttons.filter(\.isShown).count
        Form {
            Section("Вкладки") {
                ForEach(Tab.buttons) { tab in
                    Toggle(isOn: state.bind({ tab.isShown }, { state.setShown(tab.rawValue, $0) })) {
                        Label(tab.title, systemImage: tab.icon)
                    }
                    // One tab stays: the panel needs something to open.
                    .disabled(tab.isShown && shownTabs == 1)
                }
            }
            Section("Кнопки") {
                ForEach(HeaderItem.allCases) { item in
                    Toggle(isOn: state.bind({ item.isShown }, { state.setShown(item.rawValue, $0) })) {
                        Label(item.title, systemImage: item.symbol)
                    }
                }
            }
        }
    }
}

struct LauncherPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            Section {
                Toggle("Поиск в вырезе", isOn: state.bind({ Settings.launcher }, state.setLauncher))
                LabeledContent("Сочетание клавиш") {
                    ShortcutRecorder(shortcut: Settings.launcherShortcut, fallback: .launcher,
                                     onRecording: state.recordingLauncherShortcut,
                                     onChange: { state.setLauncherShortcut($0 ?? .launcher) })
                }
                .disabled(!Settings.launcher)
                if state.launcherKeyTaken {
                    Label("Сочетание занято другой программой", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Искать") {
                Toggle("Программы", isOn: state.bind({ Settings.launcherApps }, { Settings.launcherApps = $0 }))
                Toggle("Системные настройки", isOn: state.bind({ Settings.launcherSettings }, { Settings.launcherSettings = $0 }))
                Toggle("Команды Nook", isOn: state.bind({ Settings.launcherCommands }, { Settings.launcherCommands = $0 }))
                Toggle("Файлы (Spotlight)", isOn: state.bind({ Settings.launcherFiles }, { Settings.launcherFiles = $0 }))
                Toggle("Пункты меню программы впереди", isOn: state.bind({ Settings.launcherMenus }, { Settings.launcherMenus = $0 }))
                Toggle("Открытые окна", isOn: state.bind({ Settings.launcherOpenWindows }, { Settings.launcherOpenWindows = $0 }))
                Toggle("Быстрые команды macOS", isOn: state.bind({ Settings.launcherShortcuts }, { Settings.launcherShortcuts = $0 }))
                Toggle("Google и словарь внизу списка",
                       isOn: state.bind({ Settings.launcherFallbacks }, { Settings.launcherFallbacks = $0 }))
            }
            PairsSection(title: L("Быстрые ссылки"), first: L("имя"), second: "https://…{query}…",
                         load: { Settings.quicklinks }, save: { Settings.quicklinks = $0 })
            PairsSection(title: L("Свои команды"), first: L("название"), second: L("команда для zsh"),
                         load: { Settings.customCommands }, save: { Settings.customCommands = $0 })
            Section("Окна") {
                Toggle("Команды для окон: половины, трети, развернуть",
                       isOn: state.bind({ Settings.launcherWindows }, { Settings.launcherWindows = $0 }))
                LabeledContent("Сочетания клавиш") {
                    Button("Как в Rectangle (⌃⌥ + стрелки)") { state.model.launcher.useRectangleShortcuts() }
                }
                .disabled(!Settings.launcherWindows)
            }
            Section {
                LabeledContent("История запусков") {
                    Button("Очистить") { state.model.launcher.clearHistory() }
                }
            }
            LauncherItemsSection(launcher: state.model.launcher)
        }
    }
}

/// Name + text rows (quicklinks, commands), saved when a field loses focus.
struct PairsSection: View {
    let title: String
    let first: String
    let second: String
    let load: () -> [[String]]
    let save: ([[String]]) -> Void
    @State private var rows: [[String]] = []

    var body: some View {
        Section {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    TextField(first, text: binding(index, 0), prompt: Text(first)).labelsHidden().frame(width: 110)
                    TextField(second, text: binding(index, 1), prompt: Text(second)).labelsHidden()
                        .font(.system(size: 12, design: .monospaced))
                    Button { rows.remove(at: index); save(rows) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button("Добавить") { rows.append(["", ""]) }
        } header: {
            Text(title)
        }
        .onAppear { rows = load() }
    }

    private func binding(_ row: Int, _ column: Int) -> Binding<String> {
        Binding(get: { rows.indices.contains(row) ? rows[row][column] : "" }, set: { value in
            guard rows.indices.contains(row) else { return }
            rows[row][column] = value
            save(rows.filter { !$0[0].trimmingCharacters(in: .whitespaces).isEmpty && !$0[1].isEmpty })
        })
    }
}

/// Every app, pane and command with its alias and own shortcut.
struct LauncherItemsSection: View {
    @ObservedObject var launcher: Launcher
    @State private var filter = ""
    @State private var revision = 0

    var body: some View {
        let _ = revision
        let aliases = Settings.launcherAliases
        let keys = Settings.launcherHotkeys
        let typed = Launcher.fold(filter)
        let items = launcher.everything.filter { typed.isEmpty || Launcher.fold($0.title).contains(typed) }
        Section {
            TextField("Найти программу или команду", text: $filter, prompt: Text("Найти программу или команду")).labelsHidden()
            ForEach(items) { item in
                HStack(spacing: 10) {
                    LaunchIcon(item: item, icon: launcher.icon(for: item), size: 20)
                    Text(item.title).lineLimit(1)
                    Spacer(minLength: 8)
                    AliasField(alias: aliases[item.id] ?? "") { launcher.setAlias($0, for: item.id); revision += 1 }
                    ShortcutRecorder(shortcut: keys[item.id].flatMap(Shortcut.init(stored:)), fallback: nil,
                                     onRecording: { launcher.pauseHotkeys($0) },
                                     onChange: { launcher.setHotkey($0, for: item.id); revision += 1 })
                    if launcher.takenHotkeys.contains(item.id) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help("Сочетание занято другой программой")
                    }
                }
            }
        } header: {
            Text("Псевдонимы и сочетания")
        }
        .onAppear { launcher.indexIfNeeded() }
    }
}

/// Saved when the field loses focus or on ↩; trimmed, blank means none.
struct AliasField: View {
    let alias: String
    let save: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("псевдоним", text: $text, prompt: Text("псевдоним"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)
            .focused($focused)
            .onAppear { text = alias }
            .onChange(of: alias) { _, new in if !focused { text = new } }
            .onSubmit { save(text) }
            .onChange(of: focused) { _, now in if !now { save(text) } }
    }
}

struct AIPane: View {
    @ObservedObject var assistant: Assistant
    @State private var key = ""
    @State private var hasKey = Keychain.read("anthropic") != nil
    @State private var provider = Settings.aiProvider
    @State private var tested: String?

    private static let models = [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
                                 ("claude-haiku-5-5", "Claude Haiku 5.5")]

    var body: some View {
        Form {
            Section {
                Picker("Отвечает", selection: $provider) {
                    ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: provider) { _, new in Settings.aiProvider = new; tested = nil }
                switch provider {
                case .claudeCode:
                    LabeledContent("Claude Code") {
                        StatusText(ok: Assistant.claudeBinary != nil, yes: L("Найден"), no: L("Не установлен"))
                    }
                case .anthropic:
                    LabeledContent("Ключ API") {
                        HStack(spacing: 8) {
                            SecureField(hasKey ? L("сохранён в Связке ключей") : "sk-ant-…", text: $key).frame(width: 220)
                            Button("Сохранить") {
                                Keychain.save(key.trimmingCharacters(in: .whitespaces), for: "anthropic")
                                hasKey = Keychain.read("anthropic") != nil
                                key = ""
                            }
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                            if hasKey {
                                Button { Keychain.save(nil, for: "anthropic"); hasKey = false } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Удалить ключ")
                            }
                        }
                    }
                    Picker("Модель", selection: Binding(get: { Settings.aiModel }, set: { Settings.aiModel = $0; tested = nil })) {
                        ForEach(Self.models, id: \.0) { Text($0.1).tag($0.0) }
                    }
                case .apple:
                    LabeledContent("Модель Apple") {
                        StatusText(ok: Assistant.appleStatus == nil, yes: L("Готова"), no: Assistant.appleStatus ?? "")
                    }
                }
                LabeledContent("Проверка") {
                    HStack(spacing: 8) {
                        if let tested { Text(tested).foregroundStyle(.secondary).lineLimit(1) }
                        if assistant.working { ProgressView().controlSize(.small) }
                        Button("Проверить") {
                            tested = nil
                            assistant.ask(L("Ответь одним словом: столица Франции?"), title: L("Проверка")) { result in
                                switch result {
                                case .success(let text): tested = "✓ " + text.trimmingCharacters(in: .whitespacesAndNewlines)
                                case .failure(let error): tested = "✗ " + error.localizedDescription
                                }
                            }
                        }
                        .disabled(assistant.working || !assistant.isReady)
                    }
                }
            }
            Section("Действия с выделенным текстом") {
                ForEach(AIAction.allCases, id: \.self) { action in
                    Label(action.title, systemImage: action.symbol)
                }
            }
        }
    }
}

struct ClipboardPane: View {
    @ObservedObject var state: SettingsState
    @State private var ignored = Settings.clipboardIgnoredApps

    var body: some View {
        Form {
            Section {
                Picker("Хранить записи", selection: state.bind({ Settings.clipboardKeepDays }, {
                    Settings.clipboardKeepDays = $0
                    state.model.clipboard.applyKeepTime()
                })) {
                    Text("Всегда (до 300)").tag(0)
                    Text("1 день").tag(1)
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                    Text("1 год").tag(365)
                }
                LabeledContent("Открыть буфер") { Text("⌃⌘V").font(.system(size: 12, weight: .medium, design: .rounded)) }
            }
            Section("Не записывать из программ") {
                ForEach(ignored, id: \.self) { id in
                    HStack {
                        Text(Self.name(id)).lineLimit(1)
                        Spacer()
                        Button { ignored.removeAll { $0 == id }; Settings.clipboardIgnoredApps = ignored } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Добавить программу…") { addApp() }
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              !ignored.contains(id) else { return }
        ignored.append(id)
        Settings.clipboardIgnoredApps = ignored
    }

    private static func name(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct SnippetsPane: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var snippets: Snippets
    @State private var editing: Snippet?
    @State private var original: Snippet?

    var body: some View {
        Form {
            Section {
                Toggle("Раскрывать ключевые слова в любой программе", isOn: state.bind({ Settings.snippets }, {
                    Settings.snippets = $0
                    if $0 && !AXIsProcessTrusted() { state.askAccessibility() }
                    snippets.apply()
                }))
                if Settings.snippets && !state.accessibility {
                    LabeledContent("Нужен Универсальный доступ") { Button("Открыть…") { state.askAccessibility() } }
                }
            }
            if let draft = editing {
                SnippetEditor(snippet: draft, isNew: original == nil) { saved in
                    if let saved { snippets.save(saved, replacing: original) }
                    editing = nil
                    original = nil
                }
            } else {
                Section {
                    if snippets.all.isEmpty { Text("Пока нет сниппетов").foregroundStyle(.secondary) }
                    ForEach(snippets.all) { snippet in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snippet.name).lineLimit(1)
                                Text(snippet.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if !snippet.keyword.isEmpty {
                                Text(snippet.keyword).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Button("Изменить") { original = snippet; editing = snippet }
                            Button { snippets.delete(snippet) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("В корзину")
                        }
                        .opacity(snippet.enabled ? 1 : 0.5)
                    }
                    HStack {
                        Button("Новый сниппет") {
                            original = nil
                            editing = Snippet(file: Snippet.folder.appendingPathComponent("new.md"), name: "", keyword: "", text: "")
                        }
                        Spacer()
                        Button("Показать папку") {
                            try? FileManager.default.createDirectory(at: Snippet.folder, withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([Snippet.folder])
                        }
                    }
                }
            }
        }
        .onAppear { snippets.load() }
    }
}

struct SnippetEditor: View {
    @State var snippet: Snippet
    let isNew: Bool
    /// nil: cancelled.
    let done: (Snippet?) -> Void

    private static let placeholders: [(String, String)] = [
        (L("Буфер обмена"), "{clipboard}"), (L("Дата"), "{date}"), (L("Время"), "{time}"), (L("Дата и время"), "{datetime}"),
        (L("День недели"), "{day}"), (L("Дата в своём формате"), "{date format=\"dd.MM.yyyy\"}"),
        (L("Время через 1 час"), "{time offset=\"+1h\"}"), ("UUID", "{uuid}"), (L("Место курсора"), "{cursor}"),
    ]

    var body: some View {
        Section {
            TextField("Название", text: $snippet.name)
            TextField("Ключевое слово, например ;sig", text: $snippet.keyword)
            Toggle("Включён", isOn: $snippet.enabled)
            TextEditor(text: $snippet.text)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(minHeight: 120)
            HStack {
                Menu("Вставить…") {
                    ForEach(Self.placeholders, id: \.1) { item in
                        Button(item.0) { snippet.text += item.1 }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Отмена") { done(nil) }
                Button(isNew ? L("Создать") : L("Сохранить")) { done(snippet) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(snippet.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text(isNew ? L("Новый сниппет") : snippet.name)
        }
    }
}

struct NotchPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            Section {
                Toggle("Громкость и яркость", isOn: state.bind({ Settings.volumeHUD }, { Settings.volumeHUD = $0 }))
                if Settings.volumeHUD {
                    LabeledContent("Системное окно громкости") {
                        if state.model.volume.hasKeys {
                            StatusText(ok: true, yes: L("Скрыто"), no: "")
                        } else {
                            Button("Скрыть…") { state.askAccessibility() }
                        }
                    }
                }
            } header: {
                Text("Клавиши")
            }
            Section {
                Toggle("«Не беспокоить» и другие режимы", isOn: state.bind({ Settings.focusHUD }, { Settings.focusHUD = $0 }))
                if Settings.focusHUD && !state.fullDiskAccess {
                    LabeledContent("Нужен полный доступ к диску") {
                        Button("Открыть настройки…") { state.openFullDiskAccess() }
                    }
                }
            } header: {
                Text("Фокусирование")
            }
            Section {
                Toggle("Процессы, которые грузят Mac", isOn: state.bind({ Settings.processWatch }, { Settings.processWatch = $0 }))
                ForEach(Settings.ignoredProcesses.sorted(), id: \.self) { name in
                    LabeledContent(name) {
                        Button("Снова следить") { state.unignore(name) }
                    }
                }
            } header: {
                Text("Нагрузка")
            }
        }
    }
}

struct NotificationsPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            Section {
                Toggle("Показывать уведомления в вырезе",
                       isOn: state.bind({ Settings.notificationIslands }, { Settings.notificationIslands = $0 }))
                Toggle("Показывать текст уведомлений",
                       isOn: state.bind({ Settings.notificationText }, { Settings.notificationText = $0 }))
                    .disabled(!Settings.notificationIslands)
            }
            Section {
                LabeledContent("Полный доступ к диску") {
                    HStack(spacing: 10) {
                        StatusText(ok: state.fullDiskAccess, yes: L("Разрешён"), no: L("Нет доступа"))
                        if !state.fullDiskAccess { Button("Открыть…") { state.openFullDiskAccess() } }
                    }
                }
            } header: {
                Text("Доступ")
            }
            Section {
                if state.mutedApps.isEmpty {
                    Text("Нет скрытых приложений").foregroundStyle(.secondary)
                }
                ForEach(state.mutedApps) { app in
                    LabeledContent(app.name) {
                        Button("Показывать") { state.unmute(app.id) }
                    }
                }
            } header: {
                Text("Скрытые приложения")
            }
        }
    }
}

struct DictationPane: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var dictation: Dictation

    var body: some View {
        let selected = Settings.dictationModel
        Form {
            Section {
                Toggle(isOn: state.bind({ Settings.dictation }, state.setDictation)) {
                    HStack(spacing: 12) {
                        PaneIcon(pane: .dictation, size: 34)
                        Text("Включить диктовку").font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Picker("Модель", selection: state.bind({ Settings.dictationModel }, {
                    Settings.dictationModel = $0
                    dictation.unload()
                })) {
                    ForEach(ParakeetModel.allCases) { model in
                        Text("\(model.title) · \(Self.size(model.downloadSize))").tag(model).disabled(!model.isSupported)
                    }
                }
                modelStatus(selected)
                if let error = dictation.downloadError { NoteText(note: .init(ok: false, text: error)) }
            } header: {
                Text("Модель")
            }
            Section {
                LabeledContent("Сочетание клавиш") {
                    ShortcutRecorder(shortcut: Settings.dictationShortcut, fallback: .dictation, modifierAlone: true,
                                     onRecording: { dictation.paused = $0 },
                                     onChange: { state.setDictationShortcut($0 ?? .dictation) })
                }
                if dictation.shortcutTaken {
                    Label("Сочетание занято другой программой", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Picker("Как включать", selection: state.bind({ Settings.dictationMode }, { Settings.dictationMode = $0 })) {
                    ForEach(Dictation.Mode.allCases) { Text($0.title(for: Settings.dictationShortcut)).tag($0) }
                }
                SoundPicker(title: "Звук в начале", sound: state.bind({ Settings.dictationStartSound }, { Settings.dictationStartSound = $0 }))
                SoundPicker(title: "Звук в конце", sound: state.bind({ Settings.dictationEndSound }, { Settings.dictationEndSound = $0 }))
                Toggle("Приглушать звук до 5 % во время записи", isOn: state.bind({ Settings.dictationDuck }, { Settings.dictationDuck = $0 }))
            } header: {
                Text("Управление")
            }
            Section {
                Picker("Микрофон", selection: state.bind({ Settings.dictationMicrophone }, { Settings.dictationMicrophone = $0 })) {
                    Text("Как в системе").tag(String?.none)
                    ForEach(Dictation.microphones) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("Вставлять в активное приложение", isOn: state.bind({ Settings.dictationPaste }, { Settings.dictationPaste = $0 }))
                Toggle("Подстраивать заглавную букву и пробел",
                       isOn: state.bind({ Settings.dictationSmartCase }, { Settings.dictationSmartCase = $0 }))
            } header: {
                Text("Ввод")
            }
            Section {
                Picker("Выгружать модель из памяти", selection: state.bind({ Settings.dictationUnloadMinutes }, {
                    Settings.dictationUnloadMinutes = $0
                })) {
                    Text("Через 5 мин").tag(5)
                    Text("Через 15 мин").tag(15)
                    Text("Через 1 час").tag(60)
                    Text("Никогда").tag(0)
                }
            }
            Section {
                LabeledContent("Микрофон") {
                    HStack(spacing: 10) {
                        StatusText(ok: state.microphone == .authorized, yes: L("Разрешён"),
                                   no: state.microphone == .notDetermined ? L("Спросит при первой записи") : L("Нет доступа"))
                        if state.microphone == .denied || state.microphone == .restricted {
                            Button("Открыть…") { state.openMicrophone() }
                        }
                    }
                }
                LabeledContent("Универсальный доступ") {
                    HStack(spacing: 10) {
                        StatusText(ok: state.accessibility, yes: L("Разрешён"), no: L("Нет доступа"))
                        if !state.accessibility { Button("Открыть…") { state.askAccessibility() } }
                    }
                }
            } header: {
                Text("Разрешения")
            }
        }
    }

    @ViewBuilder private func modelStatus(_ model: ParakeetModel) -> some View {
        let _ = dictation.installs
        if let download = dictation.download, download.model == model {
            LabeledContent(download.preparing ? L("Готовлю модель для этого Mac…") : L("Скачиваю \(Self.size(download.done)) из \(Self.size(download.total))")) {
                HStack(spacing: 10) {
                    if download.preparing {
                        ProgressView().controlSize(.small)
                    } else {
                        ProgressView(value: Double(download.done), total: Double(max(download.total, 1))).frame(width: 120)
                        Button("Отмена") { dictation.cancelDownload() }
                    }
                }
            }
        } else if model.isInstalled {
            LabeledContent("Установлена") {
                HStack(spacing: 10) {
                    Text("\(Self.size(model.downloadSize)) на диске").foregroundStyle(.secondary)
                    Button("Удалить") { dictation.delete(model) }
                }
            }
        } else {
            LabeledContent(model.isSupported ? L("Не скачана") : L("Нужна macOS 15")) {
                Button("Скачать") { dictation.startDownload(model) }
                    .disabled(!model.isSupported || dictation.download != nil)
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A system sound or none; picking one plays it.
struct SoundPicker: View {
    let title: LocalizedStringKey
    @Binding var sound: String

    var body: some View {
        Picker(title, selection: Binding(get: { sound }, set: { sound = $0; Dictation.play($0) })) {
            Text("Без звука").tag("")
            Divider()
            ForEach(Dictation.sounds, id: \.self) { Text($0).tag($0) }
        }
    }
}

struct AgentsPane: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var agents: AgentHub

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude Code и Codex") {
                    HStack(spacing: 10) {
                        StatusText(ok: agents.hooksInstalled, yes: L("Подключены"), no: L("Не подключены"))
                        Button(agents.hooksInstalled ? L("Подключить заново") : L("Подключить")) { state.connectAgents() }
                    }
                }
                if let note = state.agentsNote { NoteText(note: note) }
            } header: {
                Text("Подключение")
            }
            Section("Сессии") {
                Toggle("Звук, когда агент закончил", isOn: state.bind({ Settings.agentDoneSound }, { Settings.agentDoneSound = $0 }))
                Picker("Убирать завершённые сессии через",
                       selection: state.bind({ Int(Settings.finishedSessionTTL / 60) }, { Settings.finishedSessionTTL = Double($0 * 60) })) {
                    ForEach([2, 10, 30, 60], id: \.self) { Text("\($0) мин").tag($0) }
                }
            }
            Section {
                LabeledContent("Острова для долгих команд (zsh)") {
                    if state.shellConnected {
                        StatusText(ok: true, yes: L("Подключено"), no: "")
                    } else {
                        Button("Подключить") { state.connectShell() }
                    }
                }
                if let note = state.shellNote { NoteText(note: note) }
            } header: {
                Text("Терминал")
            }
        }
    }
}

struct PrivacyPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            Section {
                permission(L("Универсальный доступ"), granted: state.accessibility, open: state.askAccessibility)
                permission(L("Полный доступ к диску"), granted: state.fullDiskAccess, open: state.openFullDiskAccess)
            } header: {
                Text("Разрешения macOS")
            }
            Section {
                Toggle("Скрывать Nook на скриншотах и при показе экрана",
                       isOn: state.bind({ Settings.hideFromCapture }, state.setHideFromCapture))
            }
            Section {
                LabeledContent("Данные Nook") {
                    Button("Показать в Finder") { state.showData() }
                }
            }
        }
    }

    private func permission(_ title: String, granted: Bool, open: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                StatusText(ok: granted, yes: L("Разрешён"), no: L("Нет доступа"))
                if !granted { Button("Открыть…", action: open) }
            }
        }
    }
}

struct UpdatesPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nook \(Updater.version)").font(.system(size: 17, weight: .semibold))
                        Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button { state.checkUpdates() } label: {
                        if state.checking {
                            ProgressView().controlSize(.small).frame(width: 110)
                        } else {
                            Text("Проверить сейчас").frame(minWidth: 110)
                        }
                    }
                    .disabled(state.checking)
                }
                .padding(.vertical, 4)
            }
            Section {
                Toggle("Обновлять автоматически", isOn: state.bind({ Settings.autoUpdate }, { Settings.autoUpdate = $0 }))
            }
            if let signature = state.signature {
                Section {
                    LabeledContent("Подпись", value: signature.title)
                    if signature.kind == .developerID {
                        LabeledContent("Проверка Apple") {
                            StatusText(ok: signature.notarized, yes: L("Нотаризовано"), no: L("Нет"))
                        }
                    }
                } header: {
                    Text("Эта копия")
                }
            }
            Section {
                LabeledContent("Все версии и что нового") {
                    Link("Открыть на GitHub", destination: URL(string: "https://github.com/\(Updater.repo)/releases")!)
                }
            }
        }
    }

    private var statusLine: String {
        if state.checking { return L("Проверяю…") }
        var text = state.updateText.isEmpty
            ? (Settings.autoUpdate ? L("Nook сам проверит обновления.") : L("Автоматическая проверка выключена."))
            : state.updateText
        if let checkedAt = state.checkedAt { text += L(" Проверено \(Format.when(checkedAt)).") }
        return text
    }
}

// MARK: Thanks

/// The author's USDT addresses. Checked against the QR codes from the wallet (2026-11-06).
enum Wallet: String, CaseIterable, Identifiable {
    case tron, ethereum

    var id: String { rawValue }

    var address: String {
        switch self {
        case .tron: "TDQnp3XjR1yjFhDTxUfhgRAA9YuoitR9vd"
        case .ethereum: "0x64aF41413b60d36eBf0148eA303AC3087301b2e8"
        }
    }

    var tab: String {
        switch self {
        case .tron: "TRON · TRC-20"
        case .ethereum: "Ethereum · ERC-20"
        }
    }

    var network: String {
        switch self {
        case .tron: "TRON"
        case .ethereum: "Ethereum"
        }
    }

    /// Black modules on white, one pixel per module (draw with `.interpolation(.none)`).
    var qrCode: NSImage? { Self.codes[self] ?? nil }

    private static let codes: [Wallet: NSImage?] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, qr($0.address)) })

    private static func qr(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: output.extent.size)
    }
}

struct ThanksPane: View {
    @State private var wallet = Wallet.tron
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Badge(symbol: "heart.fill", colors: [Palette.pink, Palette.violet], size: 50)
                    Text("Сказать спасибо").font(.system(size: 17, weight: .semibold))
                    Text("Nook бесплатный. Если он вам помогает, можно поблагодарить автора в USDT.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                Picker("Сеть", selection: $wallet) {
                    ForEach(Wallet.allCases) { Text($0.tab).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(alignment: .top, spacing: 18) {
                    qr
                    VStack(alignment: .leading, spacing: 10) {
                        Text("USDT · сеть \(wallet.network)").font(.system(size: 13, weight: .semibold))
                        Text(wallet.address)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: copy) {
                            Label(copied ? L("Скопировано") : L("Скопировать адрес"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Label("Только USDT и только через сеть \(wallet.network), иначе перевод пропадёт.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Ещё можно помочь") {
                LabeledContent("Звезда на GitHub") {
                    Link("Открыть репозиторий", destination: URL(string: "https://github.com/\(Updater.repo)")!)
                }
                LabeledContent("Ошибка или идея") {
                    Link("Написать", destination: URL(string: "https://github.com/\(Updater.repo)/issues/new/choose")!)
                }
            }
        }
        .onChange(of: wallet) { copied = false }
    }

    @ViewBuilder private var qr: some View {
        if let image = wallet.qrCode {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 132, height: 132)
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
                .accessibilityLabel("QR-код адреса в сети \(wallet.network)")
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(wallet.address, forType: .string)
        copied = true
        let shown = wallet
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if wallet == shown { copied = false } }
    }
}
