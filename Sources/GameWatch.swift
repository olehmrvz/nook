import AppKit

/// When Nook sleeps for an app that fills the notch's display.
enum GameSleep: String, CaseIterable, Identifiable {
    /// Games, as macOS Game Mode sees them: an app of the games category (or a known streaming app) on the whole screen.
    case games
    /// Any app in full screen.
    case any
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .games: return L("В играх")
        case .any: return L("В любой программе на весь экран")
        case .never: return L("Никогда")
        }
    }
}

/// Notices a game (or, if chosen, any app in full screen) filling the notch's display, so Nook can sleep through it: a notch over a
/// game is in the way, and hovering opens the panel in the middle of play. Driven by app switches and Space changes; a
/// look every 3 s only while a game is in front, to see it go full screen and back without a Space change.
final class GameWatch {
    /// Called on the main thread when the answer changes.
    var onChange: ((Bool) -> Void)?
    /// The notch's display, read on the main thread.
    var screen: () -> NSScreen? = { nil }
    private(set) var active = false

    /// Cloud gaming apps that do not call themselves games in their Info.plist.
    private static let gameApps: Set<String> = ["com.nvidia.gfnpc.mall"]
    /// Reads windows and app bundles: not on the main thread.
    private let queue = DispatchQueue(label: "dev.nook.gamewatch", qos: .utility)
    /// Bundle path → a game; touched on `queue` only.
    private var games: [String: Bool] = [:]
    private var timer: Timer?
    private var recheck: DispatchWorkItem?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.check(settle: true) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.check(settle: true) }
        check()
    }

    /// `settle`: once more a moment later, when a window that is going full screen has got there.
    func check(settle: Bool = false) {
        recheck?.cancel()
        if settle {
            let work = DispatchWorkItem { [weak self] in self?.check() }
            recheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
        let mode = Settings.gameSleep
        guard mode != .never, let screen = screen(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            update(false, watching: false)
            return
        }
        // Window bounds come in CG coordinates: the origin at the top left of the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let display = CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY,
                             width: screen.frame.width, height: screen.frame.height)
        let pid = app.processIdentifier
        let bundle = app.bundleURL
        let id = app.bundleIdentifier
        queue.async { [weak self] in
            guard let self else { return }
            let game = self.isGame(bundle: bundle, id: id)
            let full = (mode == .any || game) && Self.fills(pid: pid, display: display, gameLike: game)
            DispatchQueue.main.async { self.update(full, watching: game) }
        }
    }

    private func update(_ value: Bool, watching: Bool) {
        if watching && timer == nil {
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.check() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !watching {
            timer?.invalidate()
            timer = nil
        }
        guard value != active else { return }
        active = value
        onChange?(value)
    }

    /// The app calls itself a game (any `public.app-category.*games`), as Game Mode requires, or is a known one.
    private func isGame(bundle: URL?, id: String?) -> Bool {
        if let id, Self.gameApps.contains(id) { return true }
        guard let bundle else { return false }
        if let known = games[bundle.path] { return known }
        let category = Bundle(url: bundle)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? ""
        let game = category.hasPrefix("public.app-category.") && category.hasSuffix("games")
        games[bundle.path] = game
        return game
    }

    /// One of the app's ordinary windows covers the display. A game counts from just under the menu bar down (full
    /// screen on a notch display starts below the camera housing; a game in a zoomed window is still being played).
    /// Any other app counts only when it is really in full screen, so a zoomed browser does not: a window over the
    /// whole display, or macOS full screen as Accessibility reports it (that window also starts below the menu bar, whose
    /// window stays listed as the black band beside the notch).
    private static func fills(pid: pid_t, display: CGRect, gameLike: Bool) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        var whole = false
        let covered = list.contains { w in
            guard w[kCGWindowOwnerPID as String] as? pid_t == pid, w[kCGWindowLayer as String] as? Int == 0,
                  let r = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) })
            else { return false }
            guard r.minX <= display.minX + 1 && r.maxX >= display.maxX - 1 && r.maxY >= display.maxY - 1
                    && r.minY <= display.minY + 60 else { return false }
            if r.minY <= display.minY + 1 { whole = true }
            return true
        }
        guard covered, !gameLike, !whole else { return covered }
        return fullScreen(pid: pid)
    }

    /// The app's focused window is in macOS full screen. Needs Accessibility; without it only a window over the whole
    /// display counts.
    private static func fullScreen(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value) == .success else { return false }
        return value as? Bool == true
    }
}
