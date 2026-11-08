import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case home, clipboard, shelf, ai, notes, mirror, calendar, timer, cuely, launcher
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return L("Главная")
        case .clipboard: return L("Буфер")
        case .shelf: return L("Полка")
        case .ai: return L("Агенты")
        case .notes: return L("Заметки")
        case .mirror: return L("Зеркало")
        case .calendar: return L("Календарь")
        case .timer: return L("Таймер")
        case .cuely: return "Cuely"
        case .launcher: return L("Поиск")
        }
    }
    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .shelf: return "tray.full.fill"
        case .ai: return "sparkles"
        case .notes: return "note.text"
        case .mirror: return "person.crop.square"
        case .calendar: return "calendar"
        case .timer: return "timer"
        case .cuely: return "text.alignleft"
        case .launcher: return "magnifyingglass"
        }
    }
    /// ⌘1 … ⌘9 in header order (a tenth tab would get ⌘0).
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String(((Tab.allCases.firstIndex(of: self) ?? 0) + 1) % 10)))
    }

    /// Tabs drawn left of the camera; the rest go to the right.
    static let leftSide: [Tab] = [.home, .clipboard, .shelf, .ai, .notes, .mirror]
    /// Cuely has no button (it opens with `Nook --prompt`); the keyboard lock sits in its place.
    /// The search has none either: ⌥Space or the magnifier next to the gear.
    static let rightSide: [Tab] = [.calendar, .timer]
}

extension Settings {
    /// Tabs (raw values) and `HeaderItem`s switched off in Settings → Панель.
    static var headerHidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "headerHidden") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "headerHidden") }
    }
}

extension Tab {
    var isShown: Bool { !Settings.headerHidden.contains(rawValue) }
    /// The tabs that have a button, in header order.
    static var buttons: [Tab] { leftSide + rightSide }
}

/// Buttons in the panel header besides the tabs; the gear always stays (the way into Settings).
enum HeaderItem: String, CaseIterable, Identifiable {
    case weather, battery, keyLock, coffee, search

    var id: String { rawValue }
    var isShown: Bool { !Settings.headerHidden.contains(rawValue) }

    var title: String {
        switch self {
        case .weather: L("Погода")
        case .battery: L("Батарея")
        case .keyLock: L("Блокировка клавиатуры")
        case .coffee: L("Кофеин")
        case .search: L("Поиск")
        }
    }

    var symbol: String {
        switch self {
        case .weather: "cloud.sun.fill"
        case .battery: "battery.75percent"
        case .keyLock: "keyboard"
        case .coffee: "cup.and.saucer.fill"
        case .search: "magnifyingglass"
        }
    }
}

/// Tiny flashes in the side slots of the collapsed notch.
enum Flash: Equatable {
    case charging(Int)
    case screenshot(URL)
    case copied
    /// "Copy text from image" found nothing.
    case noText
    /// Output volume 0…1: the notch widens to "Звук" on the left and a level bar on the right.
    case volume(Float, muted: Bool)
    /// Built-in display brightness 0…1, same look as the volume.
    case brightness(Float)
    /// A Focus mode (Do Not Disturb…) turned on or off.
    case focus(on: Bool, name: String, symbol: String)

    /// Same for every volume level, so the bar moves instead of the slot content being replaced.
    var kind: String {
        if case .volume = self { return "volume" }
        if case .brightness = self { return "brightness" }
        return String(describing: self)
    }
}

/// A finished agent turn for the "done" island.
struct AgentTurn: Equatable {
    let provider: String
    let session: String
    let project: String
    let message: String
    let duration: TimeInterval?
    let pid: Int32
    let terminal: [String: String]
    /// "✎ 3 файла", "тесты ✓", "коммит": what the turn did besides answering.
    let summary: [AgentHub.TurnFact]
}

/// Medium pills that drop out of the notch for a few seconds.
struct Island: Identifiable, Equatable {
    enum Kind: Equatable {
        case agentDone(AgentTurn)
        case notification(bundleID: String, app: String, title: String, body: String)
        case call(name: String, bundleID: String)
        case airpods(name: String, levels: [String: Int])
        /// Automatic switching took the headphones to another device; `device` ("iPhone") when macOS names it.
        case airpodsAway(name: String, address: String, device: String?)
        case download(name: String, path: String)
        case timerDone(title: String, subtitle: String)
        case event(title: String, start: Date, url: URL?)
        case command(text: String, seconds: Double, exit: Int, pid: Int32, terminal: [String: String])
        /// Little of a Claude usage window is left.
        case limit(title: String, left: Int, resets: Date?)
        /// A process loads the Mac for a long time; `agent` is the project of the agent that started it.
        case hog(ProcessWatch.Hog, agent: String?)
        /// Dictation needs something (a model, the microphone) or reports a result.
        case dictation(title: String, detail: String, settings: Bool)
        /// A short message with a symbol: a command from the search finished, and the like.
        case notice(symbol: String, title: String, detail: String, ok: Bool)
        /// An agent waits for a permission, an answer or a plan review (`AgentHub.Permission.id`).
        case request(UUID)
        /// Two or three agents finished within a few seconds: one drop for all of them.
        case agentsDone([AgentTurn])
        /// A newer Nook is downloaded and checked: install it now or later.
        case update(version: Int)
    }
    let id = UUID()
    let created = Date()
    let kind: Kind
    var seconds: Double = 6

    /// Connected or moved away: the newer of the two replaces the older.
    var isHeadphones: Bool {
        switch kind {
        case .airpods, .airpodsAway: return true
        default: return false
        }
    }
}

enum NotchGeometry {
    /// The display chosen in the menu, else the built-in display with a camera housing, else the main display;
    /// nil for a moment during display changes. A chosen display that is disconnected falls back to the default.
    static var screen: NSScreen? {
        if let id = Settings.screenID, let chosen = NSScreen.screens.first(where: { uuid(of: $0) == id }) { return chosen }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    /// Stable across restarts and reconnects, unlike the display number.
    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func notchSize(on screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        // No physical notch: draw a small pill as tall as the menu bar.
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return CGSize(width: 200, height: max(24, min(bar, 38)))
    }
}

final class NotchModel: ObservableObject {
    static let expandedSize = CGSize(width: 780, height: 326)
    /// Larger than the open panel on every side: its shadow must fade out inside the window, or the
    /// window edge cuts it into a visible band.
    static let windowSize = CGSize(width: 900, height: 400)
    static let prompterSize = CGSize(width: 600, height: 190)
    static let ear: CGFloat = 8
    static let slot: CGFloat = 46

    @Published var expanded = false
    @Published var tab: Tab = .home {
        didSet { if tab != .clipboard { clipboardFromSearch = false } }
    }
    /// Battery details card under the header chip.
    @Published var showPower = false
    /// The limits details in place of the Agents feed.
    @Published var showLimits = false
    @Published var notch = CGSize(width: 190, height: 32)
    @Published var flash: Flash?
    /// Screens asleep or locked: the panel closes and the notch animations pause.
    @Published private(set) var resting = false
    /// A game fills the notch's display (GameWatch.swift): Nook sleeps. No notch, no hover, drops wait for the end of
    /// the game; the hotkeys still open the search and the clipboard.
    @Published private(set) var gaming = false
    /// Frame of the screen the notch lives on, set when the panel is placed (not looked up 30 times a second).
    var screenFrame = NSScreen.screens.first?.frame ?? .zero
    @Published private(set) var island: Island?
    /// The session whose reply field is open in the Agents tab.
    @Published var replyTo: String?

    let nowPlaying = NowPlaying()
    let clipboard = ClipboardStore()
    let shelf = Shelf()
    let agents = AgentHub()
    let battery = Battery()
    let limits = Limits()
    let usage = Usage()
    let processes = ProcessWatch()
    /// Focus mode: Pomodoro with coffee on and no notification islands while a focus phase runs.
    @Published private(set) var focusMode = false
    private var coffeeBeforeFocus = false
    let calendar = CalendarStore()
    let timer = FocusTimer()
    let cuely = Cuely()
    let downloads = Downloads()
    let notifications = NotificationWatcher()
    let bluetooth = AudioDevices()
    let weather = Weather()
    let notes = NotesStore()
    let mirror = MirrorCamera()
    let caffeine = Caffeine()
    let volume = VolumeControl()
    let focus = FocusWatcher()
    let keyboardLock = KeyboardLock()
    let updater = Updater()
    let gameWatch = GameWatch()
    let dictation = Dictation()
    let launcher = Launcher()
    let snippets = Snippets()
    let assistant = Assistant()
    /// Opens the Settings window (the gear in the panel; a pane, or the last one), set by the app delegate.
    var onOpenSettings: ((SettingsPane?) -> Void)?

    weak var panel: NotchPanel?
    /// Opened from the hotkey: stays open until Esc, a pick or a click outside.
    private(set) var sticky = false
    /// Bumped when a hotkey gives the panel the keyboard: the open tab focuses its field. `onAppear` alone missed
    /// the case where the tab was already open (by hover), and the typing went nowhere.
    @Published private(set) var focusRequest = 0
    /// The clipboard was opened from the search with ⌘1: Esc and ⌘1 go back there instead of closing.
    @Published private(set) var clipboardFromSearch = false
    /// Where ↩ pastes a clipboard entry: the app the panel was opened from.
    var pasteTargetName: String? { sticky && AXIsProcessTrusted() ? previousApp?.localizedName : nil }
    /// Opened for a permission request: stays open until the pointer has visited it.
    private var holdOpen = false
    /// A text field in the panel has the keyboard: leaving with the pointer would drop the text and send the rest
    /// of the typing (Return included) to the app in front.
    private var editing: Bool { panel?.isKeyWindow == true && panel?.firstResponder is NSText }
    private var previousApp: NSRunningApplication?
    /// The panel is on another display for the search; it goes back when it closes.
    private var awayScreen = false
    private var hoverStart: Date?
    private var leaveStart: Date?
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    /// A menu is open, Nook's own or another app's in the menu bar: since when. Hovering the notch must not open the
    /// panel under it (the status menu drops right beside the notch), and an open panel must not close under a
    /// context menu. Expires after 30 s in case the end of a menu goes unnoticed.
    private var menuOpenSince: Date?
    private var menuOpen: Bool { menuOpenSince.map { Date().timeIntervalSince($0) < 30 } ?? false }
    /// A file is being dragged in (the drag pasteboard changed while the button is down, and the press did not start
    /// in the open panel): the shelf shows where to drop. A tile dragged out of the shelf does not count.
    @Published private(set) var draggingFile = false
    private var pressed = false
    private var pressStartedInPanel = false
    private var tickTimer: Timer?
    private var flashWork: DispatchWorkItem?
    private var islandWork: DispatchWorkItem?
    /// Islands waiting their turn; the drop on screen shows how many ("+2").
    @Published private(set) var islandQueue: [Island] = []
    /// The pointer is on the island: it grows a step and does not go away.
    @Published private(set) var islandHovered = false

    var hasLiveActivity: Bool { flash != nil || live != nil }
    /// Asleep for a game, with nothing opened by a key on screen: the notch is not drawn.
    var hidden: Bool {
        gaming && !expanded && island == nil && flash == nil && !cuely.isPresenting && dictation.phase == .idle
    }

    /// What the collapsed notch shows on its sides, by priority.
    enum Live: Equatable { case dictation, ai, keyLock, permission, prompter, timer, download, agents, music }

    var live: Live? {
        if dictation.phase != .idle { return .dictation }
        if assistant.working && !expanded { return .ai }
        if keyboardLock.isLocked { return .keyLock }
        if !agents.permissions.isEmpty { return .permission }
        if cuely.isPresenting { return .prompter }
        if timer.isRunning || timer.isPaused { return .timer }
        if downloads.active != nil { return .download }
        if agents.indicator == .working { return .agents }
        if nowPlaying.isPlaying { return .music }
        return nil
    }

    /// Side slot width: wide for the volume bar, small for icons.
    var slotWidth: CGFloat {
        switch flash {
        case .volume, .brightness: return 104
        case .focus: return 132
        default: break
        }
        // Dictation says what it does in words: "Запись 0:07", "Распознаю".
        if flash == nil, live == .dictation { return 112 }
        if flash == nil, live == .ai { return 64 }
        return hasLiveActivity ? Self.slot : 0
    }

    var collapsedWidth: CGFloat {
        notch.width + 2 * Self.ear + 2 * slotWidth
    }

    /// The streaming model's text grows the notch into a drop of two lines under the camera while you speak.
    var dictationTextHeight: CGFloat {
        flash == nil && live == .dictation && !dictation.liveText.isEmpty ? 46 : 0
    }

    func start() {
        watchMenus()
        nowPlaying.start()
        clipboard.start()
        shelf.start { [weak self] url in self?.show(.screenshot(url), for: 3.5) }
        battery.start { [weak self] percent in self?.show(.charging(percent), for: 3) }
        limits.start()
        usage.start()
        processes.isQuiet = { [weak self] in
            guard let self else { return true }
            return DispatchQueue.main.sync { self.resting }
        }
        processes.onHog = { [weak self] hog in
            guard let self else { return }
            // The agent that started it (or the agent itself), by the PIDs Nook knows from hooks.
            let agent = hog.ancestors.lazy.compactMap { pid in self.agents.sessions.first { $0.pid == pid }?.project }.first
            self.present(Island(kind: .hog(hog, agent: agent), seconds: 20))
        }
        processes.start()
        // The Pomodoro stopped some other way (Сброс in the Timer tab): focus mode ends with it.
        timer.$pomodoro.receive(on: DispatchQueue.main).sink { [weak self] on in
            if !on { self?.endFocusMode() }
        }
        .store(in: &bag)
        // A warning when the 5-hour window runs low: once at 15 % left and once at 5 %, per window.
        limits.$claudeSession.receive(on: DispatchQueue.main).sink { [weak self] window in
            guard let self, let window else { return }
            let left = Int(max(0, 100 - window.usedPercent).rounded())
            guard let level = [5, 15].first(where: { left <= $0 }) else { return }
            let key = "\(window.resetsAt?.timeIntervalSince1970 ?? 0)-\(level)"
            guard !self.limitWarnings.contains(key) else { return }
            // Seen at launch already low: warn for the lower level only once, not for both.
            self.limitWarnings.formUnion([5, 15].filter { $0 >= level }.map { "\(window.resetsAt?.timeIntervalSince1970 ?? 0)-\($0)" })
            self.present(Island(kind: .limit(title: L("Claude · 5 ч"), left: left, resets: window.resetsAt), seconds: 8))
        }
        .store(in: &bag)
        calendar.start { [weak self] island in self?.present(island) }
        timer.onFinish = { [weak self] title, subtitle in
            self?.present(Island(kind: .timerDone(title: title, subtitle: subtitle), seconds: 8))
        }
        downloads.start { [weak self] island in self?.present(island) }
        notifications.start { [weak self] island in self?.present(island) }
        bluetooth.start { [weak self] island in self?.present(island) }
        weather.start()
        notes.start()
        // A new version is offered, never installed behind the person's back: a restart drops coffee mode, a running
        // timer, the keyboard lock and dictation.
        updater.onReady = { [weak self] version in
            self?.present(Island(kind: .update(version: version), seconds: 20))
        }
        updater.onInstallFailed = { [weak self] reason in
            self?.present(Island(kind: .notice(symbol: "exclamationmark.triangle.fill", title: L("Обновление не установлено"),
                                               detail: reason, ok: false), seconds: 8))
        }
        updater.start()
        volume.onChange = { [weak self] level, muted in
            guard let self, !self.resting, !self.expanded else { return }
            self.show(.volume(level, muted: muted), for: 1.6)
        }
        volume.onBrightness = { [weak self] level in
            guard let self, !self.resting, !self.expanded else { return }
            self.show(.brightness(level), for: 1.6)
        }
        volume.isPaused = { [weak self] in self?.keyboardLock.isLocked ?? false }
        volume.start()
        focus.onChange = { [weak self] on, name, symbol in
            guard let self, !self.resting, Settings.focusHUD else { return }
            self.show(.focus(on: on, name: name, symbol: symbol), for: 2.5)
        }
        focus.start()
        dictation.onRecording = { [weak self] on in
            guard let self else { return }
            if on, Settings.dictationDuck { self.volume.duck(to: 0.05) } else if !on { self.volume.restore() }
        }
        dictation.onNotice = { [weak self] title, detail, settings in
            self?.present(Island(kind: .dictation(title: title, detail: detail, settings: settings), seconds: 4))
        }
        dictation.start()
        snippets.clipboardHistory = { [weak self] in self?.clipboard.items.compactMap(\.text) ?? [] }
        snippets.start()
        launcher.snippets = { [weak self] in self?.snippets.all ?? [] }
        launcher.insertSnippet = { [weak self] snippet in self?.snippets.insert(snippet) }
        launcher.run = { [weak self] command in self?.run(command) }
        launcher.runAI = { [weak self] action in self?.runAI(action) }
        launcher.notify = { [weak self] symbol, title, detail, ok in
            self?.present(Island(kind: .notice(symbol: symbol, title: title, detail: detail, ok: ok), seconds: 5))
        }
        launcher.prepare()
        launcher.applyHotkeys()
        cuely.onPresentChange = { [weak self] presenting in
            guard let self else { return }
            if presenting { self.collapse(); self.startTicks() }
            self.objectWillChange.send()
            if !presenting { self.showNextIsland() }   // what came in meanwhile waited in the queue
        }
        agents.start(
            onPermission: { [weak self] in
                // Shown when the screens wake or the game ends; unanswered by then, it goes back to the terminal.
                guard let self, !self.resting, !self.gaming else { return }
                // A new request is more urgent than the limits details, on whichever tab they were opened.
                self.showLimits = false
                // The panel is open: the request is in its Agents tab. Closed: it drops out of the notch.
                if self.expanded { self.select(.ai) } else { self.presentRequest() }
            },
            onDone: { [weak self] island in self?.present(island) }
        )

        agents.$permissions.receive(on: DispatchQueue.main).sink { [weak self] list in self?.permissionsChanged(list) }
            .store(in: &bag)

        // Re-render the collapsed notch when any live source changes.
        for source in [nowPlaying.objectWillChange, agents.objectWillChange, timer.objectWillChange,
                       downloads.objectWillChange, cuely.objectWillChange, keyboardLock.objectWillChange,
                       dictation.objectWillChange, assistant.objectWillChange] {
            source.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &bag)
        }

        // No timer while the pointer is far away: moving the mouse near the notch starts fast polling,
        // which stops again once nothing there needs it (about 2.6 million fewer wakeups a day).
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.pointerMoved()
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.pointerMoved()
            return event
        }
        pointerMoved()

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.expanded, self.sticky else { return }
            if !self.expandedRect.contains(NSEvent.mouseLocation) { self.collapse() }
        }

        gameWatch.screen = { NotchGeometry.screen }
        gameWatch.onChange = { [weak self] on in self?.setGaming(on) }
        gameWatch.start()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setResting(true)
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setResting(false)
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setResting(true)
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setResting(false)
        }
        // Started while locked (e.g. reinstalled remotely): the lock notification has already passed.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true || CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            setResting(true)
        }
    }

    private func setResting(_ value: Bool) {
        guard resting != value else { return }
        resting = value
        if value {
            collapse()
        } else if !agents.permissions.isEmpty {
            // A request came in while you were away: it is the first thing you see.
            presentRequest()
        } else {
            showNextIsland()   // what finished while the screens rested
        }
    }

    private func setGaming(_ value: Bool) {
        guard gaming != value else { return }
        gaming = value
        if value {
            // Opened by a key, it stays until closed; anything else goes out of the way.
            if !sticky { collapse() }
            if let current = island, !expanded {
                if case .request = current.kind {} else { islandQueue.insert(current, at: 0) }
                dismissIsland(showNext: false)
            }
        } else if !agents.permissions.isEmpty {
            presentRequest()
        } else {
            showNextIsland()   // what came in during the game
        }
    }

    // MARK: Pointer polling

    private var fastTicks: Bool { tickTimer != nil }

    /// Something near the notch or on screen needs the pointer watched closely.
    private func needsTicks(at point: NSPoint) -> Bool {
        if expanded || island != nil || cuely.isPresenting { return true }
        // Asleep for a game: nothing near the notch reacts, so no polling while it runs.
        if gaming { return false }
        let f = screenFrame
        return f.maxY - point.y < 110 && abs(point.x - f.midX) < max(collapsedWidth, 300) / 2 + 160
    }

    private func pointerMoved() {
        guard !fastTicks, needsTicks(at: NSEvent.mouseLocation) else { return }
        startTicks()
    }

    private func startTicks() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.006
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicks() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    /// Seconds since the last keyboard or mouse input anywhere (any event type).
    private var openedAt = Date.distantPast
    private var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private var bag = Set<AnyCancellable>()
    private var limitWarnings = Set<String>()

    // MARK: Geometry in screen coordinates

    private func topRect(width: CGFloat, height: CGFloat) -> NSRect {
        let f = screenFrame
        return NSRect(x: f.midX - width / 2, y: f.maxY - height, width: width, height: height)
    }

    var hotRect: NSRect {
        let r = topRect(width: collapsedWidth + 16, height: notch.height + 6)
        return r
    }

    var expandedRect: NSRect { topRect(width: Self.expandedSize.width, height: Self.expandedSize.height) }
    var islandRect: NSRect { topRect(width: islandFrame.width, height: islandFrame.height) }
    var prompterRect: NSRect { topRect(width: Self.prompterSize.width, height: Self.prompterSize.height) }

    /// The part of the window that should take clicks right now; everything else passes through.
    private var interactiveRect: NSRect? {
        if expanded { return expandedRect.insetBy(dx: -4, dy: -4) }
        if island != nil { return islandRect }
        if cuely.isPresenting { return prompterRect }
        return nil
    }

    // MARK: Hover, drag and collapse

    private func tick() {
        let point = NSEvent.mouseLocation
        if !needsTicks(at: point) && NSEvent.pressedMouseButtons == 0 {
            if let panel, !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            hoverStart = nil
            pressed = false
            stopTicks()
            return
        }
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        if pressed && !self.pressed { pressStartedInPanel = expanded && expandedRect.contains(point) }
        self.pressed = pressed
        let dragCount = NSPasteboard(name: .drag).changeCount
        // Assigned only when it changes: this runs 30 times a second and the views watch it.
        if !pressed {
            dragBaseline = dragCount
            if draggingFile { draggingFile = false }
        } else if dragCount != dragBaseline, !draggingFile, !pressStartedInPanel {
            draggingFile = true
        }

        let interactive = interactiveRect?.contains(point) ?? false
        if let panel, panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
        let onIsland = island != nil && islandRect.contains(point)
        if onIsland != islandHovered { islandHovered = onIsland }

        let now = Date()
        if !expanded {
            leaveStart = nil
            // An island or the prompter owns the notch; hovering it does not open the panel.
            guard island == nil, !cuely.isPresenting, !menuOpen, !gaming, hotRect.contains(point) else { hoverStart = nil; return }
            if draggingFile {
                expand(tab: .shelf)
            } else if !pressed {
                if hoverStart == nil { hoverStart = now }
                if now.timeIntervalSince(hoverStart!) > 0.12 { expand() }
            }
            return
        }

        hoverStart = nil
        let inside = expandedRect.insetBy(dx: -10, dy: -10).contains(point)
        if inside { holdOpen = false }
        // The request it was opened for is answered or timed out: no reason to stay open.
        if holdOpen && agents.permissions.isEmpty { holdOpen = false }
        // Nobody at the Mac for two minutes: close, even if opened by the hotkey. An unanswered request
        // stays (it times out on its own after about two minutes, which then lets the panel close).
        // Idle for two minutes since it opened: a panel opened by a script while the person was away
        // must not close in the same second.
        if !holdOpen && Date().timeIntervalSince(openedAt) > 120 && idleSeconds > 120 { collapse(); return }
        // Typing in one of its fields (a reminder, the clipboard search): the pointer may drift away.
        if inside || sticky || holdOpen || editing || menuOpen {
            leaveStart = nil
        } else {
            if leaveStart == nil { leaveStart = now }
            if now.timeIntervalSince(leaveStart!) > 0.3 { collapse() }
        }
    }

    func expand(tab: Tab? = nil) {
        if let tab {
            self.tab = tab
        } else if !self.tab.isShown, Tab.buttons.contains(self.tab) {
            // Its button was switched off in Settings: open the first tab that still has one.
            self.tab = Tab.buttons.first(where: \.isShown) ?? .home
        }
        guard !expanded else { return }
        if island != nil { dismissIsland(showNext: false) }
        expanded = true
        openedAt = Date()
        startTicks()
    }

    /// `returnFocus: false` when the search opens an app: the app in front before must not take the screen back,
    /// so the new app opens on the display the search was on.
    func collapse(returnFocus: Bool = true) {
        guard expanded else { return }
        showPower = false
        showLimits = false
        let wasSticky = sticky
        sticky = false
        holdOpen = false
        clipboardFromSearch = false
        expanded = false
        if let panel, panel.isKeyWindow, !cuely.isPresenting {
            // Hand keyboard focus back to the app the user was in, without hiding the window
            // (ordering it out and in again made the notch blink).
            let target = wasSticky ? previousApp : NSWorkspace.shared.frontmostApplication
            if returnFocus, let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                target.activate()
            }
            panel.resignKey()
        }
        if !islandQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showNextIsland() }
        }
        if awayScreen {
            // Back to the notch's own display once the panel has closed there.
            awayScreen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { if !self.expanded { self.panel?.reposition() } }
        }
    }

    /// Opens the Agents tab with the reply field of this session, ready to type.
    func startReply(to session: String) {
        replyTo = session
        open(tab: .ai)
        focusPanel()
    }

    /// Opens a tab and keeps it open until Esc or a click outside.
    func open(tab: Tab) {
        previousApp = NSWorkspace.shared.frontmostApplication
        sticky = true
        expand(tab: tab)
    }

    /// Other apps' menus come as distributed notifications; Nook's own (the status menu, context menus in the panel)
    /// as local ones, which arrive at once even while Nook's own menu holds the main run loop.
    private func watchMenus() {
        let open: (Notification) -> Void = { [weak self] _ in self?.menuOpenSince = Date() }
        let closed: (Notification) -> Void = { [weak self] _ in self?.menuOpenSince = nil }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: NSNotification.Name("com.apple.HIToolbox.beginMenuTrackingNotification"),
                                object: nil, queue: .main, using: open)
        distributed.addObserver(forName: NSNotification.Name("com.apple.HIToolbox.endMenuTrackingNotification"),
                                object: nil, queue: .main, using: closed)
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main, using: open)
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main, using: closed)
    }

    /// The status menu opens: a panel opened only by hovering steps aside.
    func statusMenuWillOpen() {
        if expanded && !sticky { collapse(returnFocus: false) }
    }

    /// Keys the panel takes before the Edit menu, matched by key code so they work on any keyboard layout:
    /// ⌘1 switches Search ⇄ Clipboard, ⌘C copies the chosen clipboard entry (text selected in the field is
    /// copied as usual).
    func performKeyEquivalent(_ event: NSEvent) -> Bool {
        guard expanded, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
        switch Int(event.keyCode) {
        case kVK_ANSI_1 where tab == .launcher || (tab == .clipboard && clipboardFromSearch):
            switchSearchClipboard()
            return true
        case kVK_ANSI_C where tab == .clipboard:
            if let editor = panel?.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
            let items = clipboard.filtered
            guard items.indices.contains(clipboard.selection) else { return false }
            copyClip(items[clipboard.selection])
            return true
        default:
            return false
        }
    }

    /// ⌘1: the clipboard over the search, and back. The keyboard stays in the panel.
    func switchSearchClipboard() {
        if tab == .launcher {
            if !sticky { stayOpen() }
            clipboard.query = ""
            clipboard.selection = 0
            clipboardFromSearch = true
            tab = .clipboard
        } else {
            clipboardFromSearch = false
            tab = .launcher
        }
        panel?.makeKeyAndOrderFront(nil)
        focusRequest &+= 1
    }

    /// Esc anywhere in the panel: the clipboard opened from the search goes back there, everything else closes.
    func escapeKey() {
        if clipboardFromSearch { switchSearchClipboard() } else { collapse() }
    }

    /// ⌘C on a clipboard entry: onto the clipboard, nothing pasted.
    func copyClip(_ item: ClipItem) {
        clipboard.copyToPasteboard(item)
        collapse()
        show(.copied, for: 1.4)
    }

    /// A click in a list that is driven by keys (the clipboard): the panel opened by hover does not have the keyboard,
    /// so from this click on the arrows, ↩ and Esc go to it, and ↩ pastes into the app the person was in.
    func takeKeyboard() {
        stayOpen()
        if panel?.isKeyWindow != true { panel?.makeKeyAndOrderFront(nil) }
        focusRequest &+= 1
    }

    /// Keeps the panel open while the user types in it (until Esc or a click outside).
    func stayOpen() {
        if !sticky { previousApp = NSWorkspace.shared.frontmostApplication }
        sticky = true
    }

    /// Gives the panel keyboard focus, e.g. for prompter shortcuts.
    func focusPanel() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.panel?.makeKeyAndOrderFront(nil) }
    }

    /// ⌥Space (or the magnifier): the search with the keyboard in its field; again closes it.
    /// `focus: false` (`Nook --show launcher:<text>`): shows the results without taking the keyboard.
    /// `followPointer: false` keeps the notch's display (a preview from `--show launcher:<text>`).
    func toggleLauncherFromHotkey(query: String = "", focus: Bool = true, followPointer: Bool = true) {
        if expanded && sticky && tab == .launcher && query.isEmpty { collapse(); return }
        // Also when the panel is already open by hover: Esc and pasting go back to the app you are in.
        if !sticky { previousApp = NSWorkspace.shared.frontmostApplication }
        if !expanded && followPointer {
            // The display you work on, like Spotlight: the one with the pointer.
            let pointer = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }),
               screen != NotchGeometry.screen {
                panel?.reposition(on: screen)
                awayScreen = true
            }
        }
        sticky = true
        launcher.prepare()
        launcher.query = query
        expand(tab: .launcher)
        tab = .launcher
        if focus {
            panel?.makeKeyAndOrderFront(nil)
            focusRequest &+= 1
        }
    }

    /// An AI action on the selection of the app in front (from the search or its own shortcut).
    func runAI(_ action: AIAction) {
        collapse()
        guard assistant.isReady else {
            present(Island(kind: .notice(symbol: "sparkles", title: L("AI не настроен"), detail: L("Настройки Nook → AI"), ok: false), seconds: 4))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let target = NSWorkspace.shared.frontmostApplication
            Selection.read { text in
                guard let self else { return }
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.present(Island(kind: .notice(symbol: "text.cursor", title: L("Выделите текст"),
                                                      detail: action.title, ok: false), seconds: 3))
                    return
                }
                self.assistant.ask(text, title: action.title, system: action.instruction, effort: "low") { result in
                    switch result {
                    case .success(let answer):
                        let clean = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !clean.isEmpty else { return }
                        if action.replaces {
                            TextInsertion.paste(clean, into: target)
                        } else {
                            // A summary is read, not pasted: the search opens with it.
                            self.showAnswer()
                        }
                    case .failure(let error):
                        self.present(Island(kind: .notice(symbol: "exclamationmark.triangle.fill", title: action.title,
                                                          detail: error.localizedDescription, ok: false), seconds: 5))
                    }
                }
            }
        }
    }

    /// The search panel with the assistant's answer.
    func showAnswer() {
        launcher.answerMode = true
        if !sticky { previousApp = NSWorkspace.shared.frontmostApplication }
        sticky = true
        expand(tab: .launcher)
        tab = .launcher
    }

    /// A Nook command picked in the search.
    func run(_ command: NookCommand) {
        switch command {
        case .clipboard: select(.clipboard)
        case .pasteNext:
            collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.pasteNext() }
        case .shelf: select(.shelf)
        case .notes: select(.notes)
        case .calendar: select(.calendar)
        case .agents: select(.ai)
        case .timer:
            collapse()
            timer.pomodoro = false
            timer.start(minutes: 25)
        case .pomodoro:
            collapse()
            endFocusMode()
            timer.startPomodoro()
        case .focus:
            collapse()
            startFocusMode()
        case .coffee:
            collapse()
            caffeine.toggle()
        case .keyLock:
            collapse()
            keyboardLock.lock()
        case .settings: onOpenSettings?(nil)
        case .updates: onOpenSettings?(.updates)
        case .thanks: onOpenSettings?(.thanks)
        }
    }

    private var sequence = (index: 0, first: String?.none, last: Date.distantPast)

    /// "Вставить следующее из буфера" (best with its own shortcut): each press pastes the next older text, without
    /// moving it to the top. A new copy or a minute of quiet starts again from the newest.
    func pasteNext() {
        guard Date().timeIntervalSince(sequence.last) > 0.25 else { return }
        let history = clipboard.history
        if Date().timeIntervalSince(sequence.last) > 60 || history.first != sequence.first {
            sequence = (0, history.first, sequence.last)
        }
        sequence.last = Date()
        guard history.indices.contains(sequence.index) else {
            present(Island(kind: .notice(symbol: "list.number", title: L("Больше нечего вставить"),
                                         detail: L("Это была самая старая запись"), ok: true), seconds: 3))
            return
        }
        TextInsertion.paste(history[sequence.index])
        sequence.index += 1
    }

    func toggleClipboardFromHotkey() {
        if expanded && sticky { collapse(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        sticky = true
        clipboard.query = ""
        clipboard.selection = 0
        expand(tab: .clipboard)
        panel?.makeKeyAndOrderFront(nil)
        focusRequest &+= 1
    }

    /// Copies a clipboard entry and, when allowed, pastes it into the previous app.
    func pick(_ item: ClipItem) {
        clipboard.copyToPasteboard(item)
        let shouldPaste = sticky && AXIsProcessTrusted()
        let target = previousApp
        collapse()
        if shouldPaste {
            target?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { Self.sendPaste() }
        } else {
            show(.copied, for: 1.4)
        }
    }

    static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func show(_ flash: Flash, for seconds: Double) {
        // During a game only what a key press asked for: the volume and brightness keys.
        if gaming {
            switch flash {
            case .volume, .brightness: break
            default: return
            }
        }
        flashWork?.cancel()
        if self.flash?.kind == flash.kind {
            withAnimation(.easeOut(duration: 0.12)) { self.flash = flash }   // the same flash, a new value
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.flash = flash }
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.flash = nil }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Islands

    // MARK: Focus mode

    /// Notification islands wait while a focus phase runs; breaks show them again. Calls still show.
    var focusQuiet: Bool { focusMode && timer.phase == .focus && (timer.isRunning || timer.isPaused) }

    func startFocusMode() {
        guard !focusMode else { return }
        coffeeBeforeFocus = caffeine.on
        caffeine.set(true)
        timer.startPomodoro()
        focusMode = true
    }

    /// Ends focus mode and gives coffee back its earlier state; the timer is reset by the caller if needed.
    func endFocusMode() {
        guard focusMode else { return }
        focusMode = false
        caffeine.set(coffeeBeforeFocus)
    }

    /// The oldest pending request as a big drop, ahead of anything else on screen.
    func presentRequest() {
        guard let first = agents.permissions.first else { return }
        // The prompter covers drops: the request opens the panel over it, as before drops.
        if cuely.isPresenting { holdOpen = true; expand(tab: .ai); return }
        if case .request? = island?.kind { return }   // the drop on screen already shows the oldest one
        if let current = island { islandQueue.insert(current, at: 0) }
        islandWork?.cancel()
        island = nil
        showIsland(Island(kind: .request(first.id), seconds: 30))
    }

    /// A request was answered (here, in the panel or in the terminal): the next one takes the drop, or it goes.
    private func permissionsChanged(_ list: [AgentHub.Permission]) {
        islandQueue.removeAll { if case .request(let id) = $0.kind { return !list.contains { $0.id == id } }; return false }
        guard case .request(let id)? = island?.kind, !list.contains(where: { $0.id == id }) else { return }
        if let next = list.first {
            island = Island(kind: .request(next.id), seconds: 30)
            scheduleIslandDismiss(after: 30)
        } else {
            dismissIsland()
        }
    }

    func present(_ new: Island) {
        if focusQuiet, case .notification = new.kind { return }
        // While the screens rest only finished turns wait for the wake: a message or a call from hours ago is stale.
        if resting { guard case .agentDone = new.kind else { return } }
        // Agents that finish within seconds of each other share one drop instead of queueing.
        if case .agentDone(let turn) = new.kind {
            var turns: [AgentTurn]?
            if case .agentDone(let shown)? = island?.kind, shown.session != turn.session { turns = [shown, turn] }
            // Three at most fit; a fourth waits for its own drop.
            if case .agentsDone(let shown)? = island?.kind, shown.count < 3, !shown.contains(where: { $0.session == turn.session }) {
                turns = shown + [turn]
            }
            if let turns {
                island = Island(kind: .agentsDone(turns), seconds: 8)
                scheduleIslandDismiss(after: 8)
                return
            }
        }
        // Headphones that moved away and came back (or the reverse): only the latest state is true.
        if new.isHeadphones {
            islandQueue.removeAll(where: \.isHeadphones)
            if island?.isHeadphones == true { dismissIsland(showNext: false) }
        }
        if island == nil && !expanded && !cuely.isPresenting && !resting && !gaming {
            showIsland(new)
        } else if island?.kind != new.kind && !islandQueue.contains(where: { $0.kind == new.kind }) {
            islandQueue.append(new)
            if islandQueue.count > 6 { islandQueue.removeFirst() }
        }
    }

    private func showIsland(_ new: Island) {
        guard !resting, !gaming else { islandQueue.insert(new, at: 0); return }   // shown when the screens wake
        island = new
        startTicks()
        scheduleIslandDismiss(after: new.seconds)
    }

    private func scheduleIslandDismiss(after seconds: Double) {
        islandWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Keep it while the pointer rests on it.
            if self.islandHovered { self.scheduleIslandDismiss(after: 1) } else { self.dismissIsland() }
        }
        islandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismissIsland(showNext: Bool = true) {
        islandWork?.cancel()
        island = nil
        if showNext { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.showNextIsland() } }
    }

    private func showNextIsland() {
        guard island == nil, !expanded, !cuely.isPresenting, !resting, !gaming else { return }
        // A call that waited is over; other news older than ten minutes is old. Finished turns still matter.
        islandQueue.removeAll { island in
            let age = Date().timeIntervalSince(island.created)
            switch island.kind {
            case .call: return age > 30
            // macOS gives «Вернуть» 20 s; later the drop would offer it for a state that may be gone.
            case .airpodsAway: return age > 30
            case .agentDone, .agentsDone, .request: return false
            default: return age > 600
            }
        }
        guard !islandQueue.isEmpty else { return }
        showIsland(islandQueue.removeFirst())
    }

    /// Brings the terminal that runs an agent to the front.
    static func activateApp(owning pid: Int32) {
        var current = pid
        for _ in 0..<12 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                app.activate()
                return
            }
            current = parentPID(of: current)
        }
    }

    static func parentPID(of pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}

final class NotchPanel: NSPanel {
    private let model: NotchModel

    init(model: NotchModel) {
        self.model = model
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        sharingType = Settings.hideFromCapture ? .none : .readOnly
        // Only text fields take the keyboard; clicking tabs or buttons leaves typing in the terminal.
        becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: RootView(model: model))
        host.sizingOptions = []
        // The panel overlaps the camera housing; macOS would report that as a safe area and shift
        // scroll views inside it by a few points, clipping their first row.
        host.safeAreaRegions = []
        contentView = host
        reposition()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        model.performKeyEquivalent(event) || super.performKeyEquivalent(with: event)
    }

    /// On the notch's own display, or on `screen` for a while (the search opens where the pointer is).
    func reposition(on screen: NSScreen? = nil) {
        guard let screen = screen ?? NotchGeometry.screen else { return }
        model.notch = NotchGeometry.notchSize(on: screen)
        model.screenFrame = screen.frame
        let size = NotchModel.windowSize
        setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                        width: size.width, height: size.height), display: true)
    }
}
