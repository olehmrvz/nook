import AppKit
import Combine
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case home, clipboard, shelf, ai, notes, mirror, calendar, timer, cuely
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Главная"
        case .clipboard: return "Буфер"
        case .shelf: return "Полка"
        case .ai: return "Агенты"
        case .notes: return "Заметки"
        case .mirror: return "Зеркало"
        case .calendar: return "Календарь"
        case .timer: return "Таймер"
        case .cuely: return "Cuely"
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
        }
    }
    /// ⌘1 … ⌘9 in header order (a tenth tab would get ⌘0).
    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String(((Tab.allCases.firstIndex(of: self) ?? 0) + 1) % 10)))
    }

    /// Tabs drawn left of the camera; the rest go to the right.
    static let leftSide: [Tab] = [.home, .clipboard, .shelf, .ai, .notes, .mirror]
    static let rightSide: [Tab] = [.calendar, .timer, .cuely]
}

/// Tiny flashes in the side slots of the collapsed notch.
enum Flash: Equatable {
    case charging(Int)
    case screenshot(URL)
    case copied
    /// "Copy text from image" found nothing.
    case noText
}

/// Medium pills that drop out of the notch for a few seconds.
struct Island: Identifiable, Equatable {
    enum Kind: Equatable {
        case agentDone(provider: String, project: String, message: String, duration: TimeInterval?, pid: Int32,
                       terminal: [String: String])
        case notification(bundleID: String, app: String, title: String, body: String)
        case call(name: String, bundleID: String)
        case airpods(name: String, levels: [String: Int])
        case download(name: String, path: String)
        case timerDone(title: String, subtitle: String)
        case event(title: String, start: Date, url: URL?)
        case command(text: String, seconds: Double, exit: Int, pid: Int32, terminal: [String: String])
    }
    let id = UUID()
    let kind: Kind
    var seconds: Double = 6
}

enum NotchGeometry {
    /// The built-in display with a camera housing, or the main display; nil for a moment during display changes.
    static var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
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
    static let windowSize = CGSize(width: 860, height: 356)
    static let islandWidth: CGFloat = 460
    static let islandExtra: CGFloat = 78
    static let prompterSize = CGSize(width: 600, height: 190)
    static let ear: CGFloat = 8
    static let slot: CGFloat = 46

    @Published var expanded = false
    @Published var tab: Tab = .home
    /// Battery details card under the header chip.
    @Published var showPower = false
    @Published var notch = CGSize(width: 190, height: 32)
    @Published var flash: Flash?
    /// Screens asleep or locked: the panel closes and the notch animations pause.
    @Published private(set) var resting = false
    /// Frame of the screen the notch lives on, set when the panel is placed (not looked up 30 times a second).
    var screenFrame = NSScreen.screens.first?.frame ?? .zero
    @Published private(set) var island: Island?

    let nowPlaying = NowPlaying()
    let clipboard = ClipboardStore()
    let shelf = Shelf()
    let agents = AgentHub()
    let battery = Battery()
    let limits = Limits()
    let calendar = CalendarStore()
    let timer = FocusTimer()
    let cuely = Cuely()
    let downloads = Downloads()
    let notifications = NotificationWatcher()
    let bluetooth = AudioDevices()
    let weather = Weather()
    let notes = NotesStore()
    let mirror = MirrorCamera()

    weak var panel: NotchPanel?
    /// Opened from the hotkey: stays open until Esc, a pick or a click outside.
    private(set) var sticky = false
    /// Opened for a permission request: stays open until the pointer has visited it.
    private var holdOpen = false
    private var previousApp: NSRunningApplication?
    private var hoverStart: Date?
    private var leaveStart: Date?
    private var dragBaseline = NSPasteboard(name: .drag).changeCount
    private var draggingFile = false
    private var tickTimer: Timer?
    private var flashWork: DispatchWorkItem?
    private var islandWork: DispatchWorkItem?
    private var islandQueue: [Island] = []
    private var islandHovered = false

    var hasLiveActivity: Bool { flash != nil || live != nil }

    /// What the collapsed notch shows on its sides, by priority.
    enum Live: Equatable { case permission, prompter, timer, download, agents, music }

    var live: Live? {
        if !agents.permissions.isEmpty { return .permission }
        if cuely.isPresenting { return .prompter }
        if timer.isRunning || timer.isPaused { return .timer }
        if downloads.active != nil { return .download }
        if agents.indicator == .working { return .agents }
        if nowPlaying.isPlaying { return .music }
        return nil
    }

    var collapsedWidth: CGFloat {
        notch.width + 2 * Self.ear + (hasLiveActivity ? 2 * Self.slot : 0)
    }

    func start() {
        nowPlaying.start()
        clipboard.start()
        shelf.start { [weak self] url in self?.show(.screenshot(url), for: 3.5) }
        battery.start { [weak self] percent in self?.show(.charging(percent), for: 3) }
        limits.start()
        calendar.start { [weak self] island in self?.present(island) }
        timer.onFinish = { [weak self] title, subtitle in
            self?.present(Island(kind: .timerDone(title: title, subtitle: subtitle), seconds: 8))
        }
        downloads.start { [weak self] island in self?.present(island) }
        notifications.start { [weak self] island in self?.present(island) }
        bluetooth.start { [weak self] island in self?.present(island) }
        weather.start()
        notes.start()
        cuely.onPresentChange = { [weak self] presenting in
            guard let self else { return }
            if presenting { self.collapse(); self.startTicks() }
            self.objectWillChange.send()
        }
        agents.start(
            onPermission: { [weak self] in
                guard let self, !self.resting else { return }   // shown when the screens wake
                self.holdOpen = true
                self.expand(tab: .ai)
            },
            onDone: { [weak self] island in self?.present(island) }
        )

        // Re-render the collapsed notch when any live source changes.
        for source in [nowPlaying.objectWillChange, agents.objectWillChange, timer.objectWillChange,
                       downloads.objectWillChange, cuely.objectWillChange] {
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
            holdOpen = true
            expand(tab: .ai)
        }
    }

    // MARK: Pointer polling

    private var fastTicks: Bool { tickTimer != nil }

    /// Something near the notch or on screen needs the pointer watched closely.
    private func needsTicks(at point: NSPoint) -> Bool {
        if expanded || island != nil || cuely.isPresenting { return true }
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
    private var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private var bag = Set<AnyCancellable>()

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
    var islandRect: NSRect { topRect(width: Self.islandWidth, height: notch.height + Self.islandExtra) }
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
            stopTicks()
            return
        }
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let dragCount = NSPasteboard(name: .drag).changeCount
        if !pressed {
            dragBaseline = dragCount
            draggingFile = false
        } else if dragCount != dragBaseline {
            draggingFile = true
        }

        let interactive = interactiveRect?.contains(point) ?? false
        if let panel, panel.ignoresMouseEvents == interactive { panel.ignoresMouseEvents = !interactive }
        islandHovered = island != nil && islandRect.contains(point)

        let now = Date()
        if !expanded {
            leaveStart = nil
            // An island or the prompter owns the notch; hovering it does not open the panel.
            guard island == nil, !cuely.isPresenting, hotRect.contains(point) else { hoverStart = nil; return }
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
        if !holdOpen && idleSeconds > 120 { collapse(); return }
        if inside || sticky || holdOpen {
            leaveStart = nil
        } else {
            if leaveStart == nil { leaveStart = now }
            if now.timeIntervalSince(leaveStart!) > 0.3 { collapse() }
        }
    }

    func expand(tab: Tab? = nil) {
        if let tab { self.tab = tab }
        guard !expanded else { return }
        if island != nil { dismissIsland(showNext: false) }
        expanded = true
        startTicks()
    }

    func collapse() {
        guard expanded else { return }
        showPower = false
        let wasSticky = sticky
        sticky = false
        holdOpen = false
        expanded = false
        if let panel, panel.isKeyWindow, !cuely.isPresenting {
            // Hand keyboard focus back to the app the user was in, without hiding the window
            // (ordering it out and in again made the notch blink).
            let target = wasSticky ? previousApp : NSWorkspace.shared.frontmostApplication
            if let target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                target.activate()
            }
            panel.resignKey()
        }
        if !islandQueue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showNextIsland() }
        }
    }

    /// Opens a tab and keeps it open until Esc or a click outside.
    func open(tab: Tab) {
        previousApp = NSWorkspace.shared.frontmostApplication
        sticky = true
        expand(tab: tab)
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

    func toggleClipboardFromHotkey() {
        if expanded && sticky { collapse(); return }
        previousApp = NSWorkspace.shared.frontmostApplication
        sticky = true
        clipboard.query = ""
        clipboard.selection = 0
        expand(tab: .clipboard)
        panel?.makeKeyAndOrderFront(nil)
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

    private static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func show(_ flash: Flash, for seconds: Double) {
        flashWork?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.flash = flash }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.flash = nil }
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Islands

    func present(_ new: Island) {
        if island == nil && !expanded && !cuely.isPresenting {
            showIsland(new)
        } else if island?.kind != new.kind && !islandQueue.contains(where: { $0.kind == new.kind }) {
            islandQueue.append(new)
            if islandQueue.count > 6 { islandQueue.removeFirst() }
        }
    }

    private func showIsland(_ new: Island) {
        guard !resting else { return }
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
        guard island == nil, !expanded, !cuely.isPresenting, !islandQueue.isEmpty else { return }
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

    func reposition() {
        guard let screen = NotchGeometry.screen else { return }
        model.notch = NotchGeometry.notchSize(on: screen)
        model.screenFrame = screen.frame
        let size = NotchModel.windowSize
        setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                        width: size.width, height: size.height), display: true)
    }
}
