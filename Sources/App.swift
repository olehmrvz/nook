import AppKit
import SwiftUI

let supportDir: URL = {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Nook", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Owner only: clipboard history, notes and agent sessions live here; some files are rewritten
    // atomically and would otherwise come back readable by other users of the Mac.
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}()

@main
enum NookMain {
    static func main() {
        if CommandLine.arguments.contains("--install-hooks") {
            let result = AgentHub.installHooks()
            print(result.message)
            exit(result.ok ? 0 : 1)
        }
        // Scripting for Raycast / Shortcuts:
        //   --show <tab|settings[:pane]|close>   --timer <minutes|stop|pomodoro|focus>   --prompt (start Cuely)
        //   --dictate [start|stop|cancel|toggle]
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag) else { return nil }
            return args.indices.contains(i + 1) ? args[i + 1] : ""
        }
        var command = value(after: "--show")
        if let t = value(after: "--timer") { command = t == "stop" ? "timer-stop" : (t == "pomodoro" || t == "focus" ? t : "timer:\(t)") }
        if args.contains("--prompt") { command = "prompt" }
        if let d = value(after: "--dictate") { command = "dictate:\(d.isEmpty ? "toggle" : d)" }
        if let command {
            exit(AgentHub.sendCommand(["event": "Show", "name": command.isEmpty ? "home" : command]) ? 0 : 1)
        }
        // `Nook --answer allow|always|deny|terminal` answers the oldest pending agent request.
        // Goes through the owner-only socket with the token: a broadcast notification could be sent
        // (and approve an agent's request) by any process on the Mac.
        if let i = CommandLine.arguments.firstIndex(of: "--answer") {
            let answer = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "allow"
            exit(AgentHub.sendCommand(["event": "Answer", "decision": answer]) ? 0 : 1)
        }
        // Only "--" options are Nook's; macOS itself may pass "-psn_…" or "-NS…" ones at launch.
        if let unknown = args.dropFirst().first(where: { $0.hasPrefix("--") }) {
            // A typo must not start a second Nook: two copies would overwrite each other's files.
            print("Nook: unknown option \(unknown)")
            print("Usage: Nook --show <tab|power|settings[:pane]|close> | --timer <min|stop|pomodoro|focus> | --prompt | --dictate [start|stop|cancel|toggle] | --answer <allow|always|deny|terminal> | --install-hooks")
            exit(2)
        }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.nook.app")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            // Opened again from Finder or Spotlight: the running copy shows itself (and its menu bar icon).
            _ = AgentHub.sendCommand(["event": "Show", "name": "reveal"])
            print("Nook is already running")
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = NotchModel()
    var panel: NotchPanel!
    var statusItem: NSStatusItem!
    var settings: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NotchPanel(model: model)
        model.panel = panel
        panel.orderFrontRegardless()
        model.start()
        setupStatusItem()
        settings = SettingsWindowController(state: SettingsState(model: model, app: self))
        model.onOpenSettings = { [weak self] pane in
            self?.model.collapse()
            self?.settings.show(pane)
        }
        LoginItem.followApp()

        HotKey.register(id: 1, keyCode: 9 /* V */, modifiers: HotKey.control | HotKey.command) { [weak self] in
            self?.model.toggleClipboardFromHotkey()
        }
        applyLauncherHotKey()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.panel.reposition()
        }
        model.agents.onShow = { [weak self] name in self?.handle(command: name) }
    }

    /// Commands from the `Nook` command line, delivered over the authenticated socket.
    private func handle(command name: String) {
        if name == "close" { model.collapse(); model.cuely.stop(); return }
        if name == "reveal" { reveal(); return }
        if name == "prompt" { model.cuely.present(); model.focusPanel(); return }
        if name.hasPrefix("dictate:") {
            switch name.dropFirst("dictate:".count) {
            case "start": model.dictation.begin()
            case "stop": model.dictation.finish()
            case "cancel": model.dictation.cancel()
            default: model.dictation.toggle()
            }
            return
        }
        if name == "launcher" || name.hasPrefix("launcher:") {
            let query = String(name.dropFirst("launcher:".count))
            model.toggleLauncherFromHotkey(query: query, focus: query.isEmpty)
            return
        }
        if name == "settings" || name.hasPrefix("settings:") {
            settings.show(SettingsPane(rawValue: String(name.dropFirst("settings:".count))))
            return
        }
        if name.hasPrefix("timer:"), let minutes = Double(name.dropFirst(6)) {
            model.timer.pomodoro = false
            model.timer.start(minutes: minutes)
            return
        }
        if name == "pomodoro" { model.endFocusMode(); model.timer.startPomodoro(); return }
        if name == "focus" { model.startFocusMode(); return }
        if name == "power" { model.open(tab: .home); model.showPower = true; return }
        if name == "timer-stop" { model.timer.reset(); return }
        model.open(tab: Tab(rawValue: name) ?? .home)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Nook")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible = Settings.showMenuIcon
    }

    /// Built fresh on every opening, so the coffee state is current.
    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    /// Quick actions only; everything else lives in the Settings window.
    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        @discardableResult func item(_ title: String, _ action: Selector, symbol: String, key: String = "") -> NSMenuItem {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return entry
        }

        item("Открыть Nook", #selector(openHome), symbol: "rectangle.topthird.inset.filled")
        item("Буфер обмена  ⌃⌘V", #selector(openClipboard), symbol: "doc.on.clipboard")
        item(model.caffeine.on ? "Кофеин включён — Mac не засыпает" : "Кофеин: не давать Mac засыпать",
             #selector(toggleCaffeine), symbol: "cup.and.saucer").state = model.caffeine.on ? .on : .off
        menu.addItem(.separator())
        item("Настройки…", #selector(openSettings), symbol: "gearshape", key: ",")
        item("Проверить обновления…", #selector(checkUpdates), symbol: "arrow.down.circle")
        item("Сказать спасибо…", #selector(openThanks), symbol: "heart")
        menu.addItem(.separator())
        item("Выйти из Nook", #selector(NSApplication.terminate(_:)), symbol: "power", key: "q").target = NSApp
    }

    @objc private func openHome() { model.open(tab: .home) }
    @objc private func openClipboard() { model.toggleClipboardFromHotkey() }
    @objc private func toggleCaffeine() { model.caffeine.toggle() }
    @objc private func openSettings() { settings.show() }
    @objc private func openThanks() { settings.show(.thanks) }

    @objc private func checkUpdates() {
        settings.show(.updates)
        settings.state.checkUpdates()
    }

    /// The search shortcut from Settings; false when another app holds that combination.
    /// `paused`: while a new one is being recorded, so pressing the old one records instead of opening the search.
    @discardableResult
    func applyLauncherHotKey(paused: Bool = false) -> Bool {
        HotKey.unregister(id: 2)
        guard Settings.launcher, !paused else { return true }
        let shortcut = Settings.launcherShortcut
        return HotKey.register(id: 2, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.model.toggleLauncherFromHotkey()
        }
    }

    /// From the Settings window.
    func chooseScreen(_ id: String?) {
        Settings.screenID = id
        model.collapse()
        panel.reposition()
    }

    /// From the Settings window: its footnote says how to get the icon back.
    func setMenuIcon(_ on: Bool) {
        Settings.showMenuIcon = on
        statusItem.isVisible = on
    }

    /// Nook opened again while it runs (Finder, Spotlight): bring the icon back and show the panel.
    func reveal() {
        Settings.showMenuIcon = true
        statusItem.isVisible = true
        model.open(tab: .home)
    }
}

enum LoginItem {
    static let label = "dev.nook.app"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    /// The plist is read and written off the main thread.
    private static let queue = DispatchQueue(label: "nook.loginitem")

    /// The app moved (e.g. ~/Applications → /Applications): point the login item at the current copy.
    static func followApp() {
        queue.async {
            guard isEnabled, let plist = NSDictionary(contentsOf: plistURL),
                  let arguments = plist["ProgramArguments"] as? [String], arguments.last != Bundle.main.bundlePath else { return }
            write(true)
        }
    }

    static func setEnabled(_ on: Bool) {
        queue.async { write(on) }
    }

    private static func write(_ on: Bool) {
        if on {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: plistURL, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}
