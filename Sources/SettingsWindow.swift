import AppKit
import AVFoundation
import Combine
import CoreImage
import Security
import SwiftUI

/// Sections of the Settings window, in sidebar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notch, notifications, dictation, agents, privacy, updates, thanks

    var id: String { rawValue }
    /// The first group in the sidebar: what Nook does. The second one is about Nook itself.
    static let settings: [SettingsPane] = [.general, .notch, .notifications, .dictation, .agents, .privacy]
    static let about: [SettingsPane] = [.updates, .thanks]

    var title: String {
        switch self {
        case .general: "Основные"
        case .notch: "Вырез"
        case .notifications: "Уведомления"
        case .dictation: "Диктовка"
        case .agents: "Агенты"
        case .privacy: "Приватность"
        case .updates: "Обновления"
        case .thanks: "Спасибо автору"
        }
    }

    var summary: String {
        switch self {
        case .general: "Запуск, значок в строке меню и экран для выреза."
        case .notch: "Что вырез показывает сам, без открытой панели."
        case .notifications: "Уведомления приложений и звонки островом в вырезе."
        case .dictation: "Речь в текст на этом Mac, без интернета."
        case .agents: "Claude Code и Codex: статус, вопросы и ответы в вырезе."
        case .privacy: "Разрешения macOS, скриншоты и где лежат данные."
        case .updates: "Версия, подпись и обновления с GitHub."
        case .thanks: "Поддержать автора Nook."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
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
        window.title = "Настройки Nook"
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
        case .local: "Локальный сертификат Nook"
        case .other: name
        case .adHoc: "Без постоянной подписи"
        }
    }

    var explanation: String {
        switch kind {
        case .developerID where notarized:
            "Подписано сертификатом разработчика и проверено Apple: macOS открывает Nook без предупреждений."
        case .developerID:
            "Подписано сертификатом разработчика. Эту сборку Apple ещё не проверяла (нотаризация), её собрали на этом Mac."
        case .local:
            "Подписано сертификатом «Nook Local Signing». macOS сохраняет разрешения между сборками."
        case .other:
            "Обновление установится, только если оно подписано так же, как эта копия."
        case .adHoc:
            "Сборка без сертификата: macOS будет заново спрашивать разрешения, а обновления с GitHub не установятся."
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

/// The first row of a pane: its icon, name and what it is about.
struct PaneHeader: View {
    let pane: SettingsPane

    var body: some View {
        Section {
            HStack(spacing: 12) {
                PaneIcon(pane: pane, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title).font(.system(size: 15, weight: .semibold))
                    Text(pane.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
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

struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Panes

struct GeneralPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            PaneHeader(pane: .general)
            Section {
                Toggle("Запускать при входе в систему", isOn: state.bind({ state.loginItem }, state.setLoginItem))
                Toggle("Значок в строке меню", isOn: state.bind({ Settings.showMenuIcon }, state.setMenuIcon))
            } header: {
                Text("Запуск")
            } footer: {
                Footnote("Без значка настройки открываются шестерёнкой ⚙︎ в панели Nook. Значок вернётся, если снова открыть Nook из «Программ» или Spotlight.")
            }
            Section {
                Picker("Вырез на экране", selection: state.bind({ Settings.screenID }, state.chooseScreen)) {
                    Text(NSScreen.screens.contains { $0.safeAreaInsets.top > 0 } ? "Автоматически (экран с вырезом)" : "Автоматически")
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
            } footer: {
                Footnote("На экране без выреза Nook рисует сверху небольшую капсулу.")
            }
            Section("Быстрый доступ") {
                LabeledContent("Открыть панель", value: "Навести указатель на вырез")
                LabeledContent("Буфер обмена") { Text("⌃⌘V").font(.system(size: 12, weight: .medium, design: .rounded)) }
            }
            Section {
                HStack {
                    Footnote("Nook останется выключен до следующего запуска.")
                    Spacer()
                    Button("Выйти из Nook") { NSApp.terminate(nil) }
                }
            }
        }
    }
}

struct NotchPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            PaneHeader(pane: .notch)
            Section {
                Toggle("Громкость и яркость", isOn: state.bind({ Settings.volumeHUD }, { Settings.volumeHUD = $0 }))
                if Settings.volumeHUD {
                    LabeledContent("Системное окно громкости") {
                        if state.model.volume.hasKeys {
                            StatusText(ok: true, yes: "Скрыто", no: "")
                        } else {
                            Button("Скрыть…") { state.askAccessibility() }
                        }
                    }
                }
            } header: {
                Text("Клавиши")
            } footer: {
                Footnote("Чтобы системное окно не появлялось поверх выреза, Nook нужен Универсальный доступ: тогда клавиши громкости и яркости обрабатывает он.")
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
            } footer: {
                Footnote("Вырез коротко показывает, что режим включился или выключился.")
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
            } footer: {
                Footnote("Остров появится, если ваш процесс 2 минуты держит больше 90 % процессора или занимает больше 4 ГБ памяти. Скрытые из острова процессы перечислены здесь.")
            }
        }
    }
}

struct NotificationsPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            PaneHeader(pane: .notifications)
            Section {
                Toggle("Показывать уведомления в вырезе",
                       isOn: state.bind({ Settings.notificationIslands }, { Settings.notificationIslands = $0 }))
                Toggle("Показывать текст уведомлений",
                       isOn: state.bind({ Settings.notificationText }, { Settings.notificationText = $0 }))
                    .disabled(!Settings.notificationIslands)
            } footer: {
                Footnote("Текст выключен по умолчанию: вырез не учитывает настройку «Показывать миниатюры», и коды и сообщения увидит любой рядом.")
            }
            Section {
                LabeledContent("Полный доступ к диску") {
                    HStack(spacing: 10) {
                        StatusText(ok: state.fullDiskAccess, yes: "Разрешён", no: "Нет доступа")
                        if !state.fullDiskAccess { Button("Открыть…") { state.openFullDiskAccess() } }
                    }
                }
            } header: {
                Text("Доступ")
            } footer: {
                Footnote("Nook только читает базу Центра уведомлений. Без этого доступа острова уведомлений не появляются.")
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
            } footer: {
                Footnote("Приложение скрывается из меню острова: «Не показывать от…».")
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Включить диктовку").font(.system(size: 15, weight: .semibold))
                            Text("Речь в текст на этом Mac, без интернета. Звук не сохраняется.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
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
            } footer: {
                Footnote("\(selected.detail). Parakeet понимает 25 языков, среди них русский, украинский, английский, немецкий и польский; язык определяет сам. Модель скачивается один раз с Hugging Face, каждый файл проверяется по контрольной сумме.")
            }
            Section {
                Picker("Клавиша", selection: state.bind({ Settings.dictationKey }, { Settings.dictationKey = $0 })) {
                    ForEach(Dictation.Key.allCases) { Text($0.title).tag($0) }
                }
                Picker("Как включать", selection: state.bind({ Settings.dictationMode }, { Settings.dictationMode = $0 })) {
                    ForEach(Dictation.Mode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Звуки в начале и в конце", isOn: state.bind({ Settings.dictationSounds }, { Settings.dictationSounds = $0 }))
            } header: {
                Text("Управление")
            } footer: {
                Footnote(Settings.dictationMode == .hold
                         ? "Удерживайте клавишу и говорите. Отпустите: текст появится там, где курсор. Return тоже заканчивает, Escape отменяет."
                         : "Нажмите клавишу дважды и говорите. Нажмите ещё раз, чтобы закончить. Return тоже заканчивает, Escape отменяет.")
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
            } footer: {
                Footnote(Settings.dictationPaste
                         ? "Текст вставляется через буфер обмена, потом в буфере снова то, что было. В начале предложения первая буква становится заглавной, а сразу после слова добавляется пробел."
                         : "Текст только копируется в буфер обмена: вставьте его сами, ⌘V.")
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
            } footer: {
                Footnote("Загруженная модель занимает память. После выгрузки следующая диктовка начнётся чуть позже.")
            }
            Section {
                LabeledContent("Микрофон") {
                    HStack(spacing: 10) {
                        StatusText(ok: state.microphone == .authorized, yes: "Разрешён",
                                   no: state.microphone == .notDetermined ? "Спросит при первой записи" : "Нет доступа")
                        if state.microphone == .denied || state.microphone == .restricted {
                            Button("Открыть…") { state.openMicrophone() }
                        }
                    }
                }
                LabeledContent("Универсальный доступ") {
                    HStack(spacing: 10) {
                        StatusText(ok: state.accessibility, yes: "Разрешён", no: "Нет доступа")
                        if !state.accessibility { Button("Открыть…") { state.askAccessibility() } }
                    }
                }
            } header: {
                Text("Разрешения")
            } footer: {
                Footnote("Универсальный доступ нужен, чтобы Nook замечал клавишу диктовки и вставлял текст. Модель: NVIDIA Parakeet TDT 0.6B v3, сборки moondream (Ultra, Redux) и FluidInference для Core ML, лицензия CC-BY-4.0.")
            }
        }
    }

    @ViewBuilder private func modelStatus(_ model: ParakeetModel) -> some View {
        let _ = dictation.installs
        if let download = dictation.download, download.model == model {
            LabeledContent(download.preparing ? "Готовлю модель для этого Mac…" : "Скачиваю \(Self.size(download.done)) из \(Self.size(download.total))") {
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
            LabeledContent(model.isSupported ? "Не скачана" : "Нужна macOS 15") {
                Button("Скачать") { dictation.startDownload(model) }
                    .disabled(!model.isSupported || dictation.download != nil)
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct AgentsPane: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var agents: AgentHub

    var body: some View {
        Form {
            PaneHeader(pane: .agents)
            Section {
                LabeledContent("Claude Code и Codex") {
                    HStack(spacing: 10) {
                        StatusText(ok: agents.hooksInstalled, yes: "Подключены", no: "Не подключены")
                        Button(agents.hooksInstalled ? "Подключить заново" : "Подключить") { state.connectAgents() }
                    }
                }
                if let note = state.agentsNote { NoteText(note: note) }
            } header: {
                Text("Подключение")
            } footer: {
                Footnote("Nook добавляет свои хуки в ~/.claude/settings.json и ~/.codex/hooks.json, другие хуки не трогает. Уже запущенных агентов перезапустите.")
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
                        StatusText(ok: true, yes: "Подключено", no: "")
                    } else {
                        Button("Подключить") { state.connectShell() }
                    }
                }
                if let note = state.shellNote { NoteText(note: note) }
            } header: {
                Text("Терминал")
            } footer: {
                Footnote("Добавляет одну строку в ~/.zshrc (сначала делает копию). Остров появится, когда команда работала дольше 20 с.")
            }
        }
    }
}

struct PrivacyPane: View {
    @ObservedObject var state: SettingsState

    var body: some View {
        Form {
            PaneHeader(pane: .privacy)
            Section {
                permission("Универсальный доступ", use: "Автовставка из буфера, клавиши громкости и яркости",
                           granted: state.accessibility, open: state.askAccessibility)
                permission("Полный доступ к диску", use: "Уведомления и «Не беспокоить» в вырезе",
                           granted: state.fullDiskAccess, open: state.openFullDiskAccess)
            } header: {
                Text("Разрешения macOS")
            } footer: {
                Footnote("В Системных настройках Nook включён, а здесь «Нет доступа»? Выключите Nook в списке и включите снова. Так бывает после того, как у Nook сменилась подпись.")
            }
            Section {
                Toggle("Скрывать Nook на скриншотах и при показе экрана",
                       isOn: state.bind({ Settings.hideFromCapture }, state.setHideFromCapture))
            } footer: {
                Footnote("Записи экрана и созвоны не увидят панель и острова.")
            }
            Section {
                LabeledContent("Данные Nook") {
                    Button("Показать в Finder") { state.showData() }
                }
            } footer: {
                Footnote("Всё хранится только на этом Mac, в ~/Library/Application Support/Nook, и доступно только вашей учётной записи. В сеть Nook выходит только за погодой (Open-Meteo), обновлениями (GitHub) и моделью для диктовки, один раз, когда вы её скачиваете (Hugging Face). Звук диктовки остаётся на Mac.")
            }
        }
    }

    private func permission(_ title: String, use: String, granted: Bool, open: @escaping () -> Void) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                StatusText(ok: granted, yes: "Разрешён", no: "Нет доступа")
                if !granted { Button("Открыть…", action: open) }
            }
        } label: {
            Text(title)
            Text(use)
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
            } footer: {
                Footnote("Раз в 6 часов Nook смотрит новый релиз на GitHub. Новая версия ставится, только если её подписал автор Nook, и только пока панель закрыта. Потом Nook перезапускается сам.")
            }
            if let signature = state.signature {
                Section {
                    LabeledContent("Подпись", value: signature.title)
                    if signature.kind == .developerID {
                        LabeledContent("Проверка Apple") {
                            StatusText(ok: signature.notarized, yes: "Нотаризовано", no: "Нет")
                        }
                    }
                } header: {
                    Text("Эта копия")
                } footer: {
                    Footnote(signature.explanation)
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
        if state.checking { return "Проверяю…" }
        var text = state.updateText.isEmpty
            ? (Settings.autoUpdate ? "Nook сам проверит обновления." : "Автоматическая проверка выключена.")
            : state.updateText
        if let checkedAt = state.checkedAt { text += " Проверено \(Format.when(checkedAt))." }
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
                    Text("Nook бесплатный и с открытым кодом. Если он экономит вам время, можно поблагодарить автора переводом в USDT. Любая сумма помогает делать Nook лучше.")
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
                            Label(copied ? "Скопировано" : "Скопировать адрес", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Label("Отправляйте только USDT и только через сеть \(wallet.network). Монеты из другой сети пропадут. Меньше 0.01 USDT не зачисляется.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            } footer: {
                Footnote("После вставки сверьте начало и конец адреса.")
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
