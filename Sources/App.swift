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
        //   --show <tab|close>   --timer <minutes|stop|pomodoro>   --prompt (start Cuely)
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag) else { return nil }
            return args.indices.contains(i + 1) ? args[i + 1] : ""
        }
        var command = value(after: "--show")
        if let t = value(after: "--timer") { command = t == "stop" ? "timer-stop" : (t == "pomodoro" ? "pomodoro" : "timer:\(t)") }
        if args.contains("--prompt") { command = "prompt" }
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
            print("Usage: Nook --show <tab|power|close> | --timer <min|stop|pomodoro> | --prompt | --answer <allow|always|deny|terminal> | --install-hooks")
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = NotchPanel(model: model)
        model.panel = panel
        panel.orderFrontRegardless()
        model.start()
        setupStatusItem()

        HotKey.register(id: 1, keyCode: 9 /* V */, modifiers: HotKey.control | HotKey.command) { [weak self] in
            self?.model.toggleClipboardFromHotkey()
        }

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
        if name.hasPrefix("timer:"), let minutes = Double(name.dropFirst(6)) {
            model.timer.pomodoro = false
            model.timer.start(minutes: minutes)
            return
        }
        if name == "pomodoro" { model.timer.startPomodoro(); return }
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
        model.onOpenMenu = { [weak self] in self?.popUpMenu() }
    }

    /// The same menu from the gear in the panel: the only way in when the menu bar icon is hidden.
    private func popUpMenu() {
        let menu = NSMenu()
        fill(menu)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Built fresh on every opening, so ticks, displays and the update status are current.
    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        @discardableResult func item(_ title: String, _ action: Selector, on: Bool? = nil, key: String = "", to parent: NSMenu? = nil) -> NSMenuItem {
            let entry = (parent ?? menu).addItem(withTitle: title, action: action, keyEquivalent: key)
            entry.target = self
            if let on { entry.state = on ? .on : .off }
            return entry
        }
        func submenu(_ title: String, symbol: String) -> NSMenu {
            let entry = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            let sub = NSMenu()
            sub.autoenablesItems = false
            entry.submenu = sub
            return sub
        }
        func header(_ title: String, in parent: NSMenu) {
            parent.addItem(NSMenuItem.sectionHeader(title: title))
        }

        item("Открыть Nook", #selector(openHome)).image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: nil)
        item("Буфер обмена  ⌃⌘V", #selector(openClipboard)).image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        let coffee = item(model.caffeine.on ? "Кофеин включён — Mac не засыпает" : "Кофеин: не давать Mac засыпать",
                          #selector(toggleCaffeine), on: model.caffeine.on)
        coffee.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
        menu.addItem(.separator())

        // Display
        let screens = submenu("Экран", symbol: "display")
        let builtIn = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        item("Автоматически" + (builtIn != nil ? " (экран с вырезом)" : ""), #selector(chooseScreen(_:)),
             on: Settings.screenID == nil, to: screens).representedObject = nil
        screens.addItem(.separator())
        for screen in NSScreen.screens {
            guard let id = NotchGeometry.uuid(of: screen) else { continue }
            let entry = item(screen.localizedName, #selector(chooseScreen(_:)), on: Settings.screenID == id, to: screens)
            entry.representedObject = id
        }

        // Agents
        let agents = submenu("Агенты", symbol: "sparkles")
        header(model.agents.hooksInstalled ? "Claude Code и Codex подключены" : "Claude Code и Codex не подключены", in: agents)
        item(model.agents.hooksInstalled ? "Подключить заново" : "Подключить Claude Code и Codex", #selector(installHooks), to: agents)
        item("Звук, когда агент закончил", #selector(toggleAgentSound(_:)), on: Settings.agentDoneSound, to: agents)
        agents.addItem(.separator())
        header("Убирать завершённые сессии через", in: agents)
        for minutes in [2, 10, 30, 60] {
            let entry = item("\(minutes) мин", #selector(chooseSessionTTL(_:)),
                             on: Int(Settings.finishedSessionTTL / 60) == minutes, to: agents)
            entry.tag = minutes
        }
        agents.addItem(.separator())
        item("Острова для долгих команд (zsh)…", #selector(installShell), to: agents)

        // Notifications
        let notes = submenu("Уведомления", symbol: "bell")
        item("Показывать уведомления приложений в вырезе", #selector(toggleNotificationIslands(_:)),
             on: Settings.notificationIslands, to: notes)
        item("Показывать текст уведомлений", #selector(toggleNotificationText), on: Settings.notificationText, to: notes)
        item("Дать полный доступ к диску…", #selector(openDiskAccess), to: notes)
        let muted = Settings.mutedApps.count
        item(muted > 0 ? "Снова показывать скрытые приложения (\(muted))" : "Скрытых приложений нет",
             #selector(unmuteApps), to: notes).isEnabled = muted > 0

        // Privacy and access
        let privacy = submenu("Доступ и приватность", symbol: "lock")
        item("Скрывать Nook в скриншотах и при показе экрана", #selector(toggleHideFromCapture(_:)),
             on: Settings.hideFromCapture, to: privacy)
        item("Автовставка из буфера (Универсальный доступ)…", #selector(askAccessibility), to: privacy)

        menu.addItem(.separator())
        item("Запускать при входе", #selector(toggleLogin(_:)), on: LoginItem.isEnabled)
        item("Значок в строке меню", #selector(toggleMenuIcon), on: Settings.showMenuIcon)

        // Updates
        let updates = submenu("Обновления · версия \(Updater.version)", symbol: "arrow.down.circle")
        if !model.updater.status.isEmpty { header(model.updater.status, in: updates) }
        item("Проверить сейчас", #selector(checkUpdates), to: updates)
        item("Обновлять автоматически", #selector(toggleAutoUpdate(_:)), on: Settings.autoUpdate, to: updates)

        menu.addItem(.separator())
        item("Выйти из Nook", #selector(NSApplication.terminate(_:)), key: "q").target = NSApp
    }

    @objc private func openHome() { model.open(tab: .home) }
    @objc private func openClipboard() { model.toggleClipboardFromHotkey() }
    @objc private func toggleCaffeine() { model.caffeine.toggle() }

    @objc private func chooseScreen(_ sender: NSMenuItem) {
        Settings.screenID = sender.representedObject as? String
        model.collapse()
        panel.reposition()
    }

    @objc private func chooseSessionTTL(_ sender: NSMenuItem) { Settings.finishedSessionTTL = Double(sender.tag * 60) }

    @objc private func toggleLogin(_ sender: NSMenuItem) { LoginItem.setEnabled(!LoginItem.isEnabled) }
    @objc private func toggleAgentSound(_ sender: NSMenuItem) { Settings.agentDoneSound.toggle() }
    @objc private func toggleNotificationIslands(_ sender: NSMenuItem) { Settings.notificationIslands.toggle() }
    @objc private func toggleNotificationText() { Settings.notificationText.toggle() }
    @objc private func toggleAutoUpdate(_ sender: NSMenuItem) { Settings.autoUpdate.toggle() }

    @objc private func toggleHideFromCapture(_ sender: NSMenuItem) {
        Settings.hideFromCapture.toggle()
        panel.sharingType = Settings.hideFromCapture ? .none : .readOnly
    }

    @objc private func toggleMenuIcon() {
        if Settings.showMenuIcon {
            let alert = NSAlert()
            alert.messageText = "Убрать значок Nook из строки меню?"
            alert.informativeText = "Меню останется под шестерёнкой ⚙︎ в панели Nook. Значок вернётся, если снова открыть Nook из папки «Программы» или через Spotlight."
            alert.addButton(withTitle: "Убрать")
            alert.addButton(withTitle: "Отмена")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Settings.showMenuIcon.toggle()
        statusItem.isVisible = Settings.showMenuIcon
    }

    /// Nook opened again while it runs (Finder, Spotlight): bring the icon back and show the panel.
    func reveal() {
        Settings.showMenuIcon = true
        statusItem.isVisible = true
        model.open(tab: .home)
    }

    @objc private func checkUpdates() {
        model.updater.check(manual: true) { text in
            let alert = NSAlert()
            alert.messageText = "Nook \(Updater.version)"
            alert.informativeText = text
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openDiskAccess() { NotificationWatcher.openSettings() }
    @objc private func unmuteApps() { Settings.mutedApps = [] }

    @objc private func askAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @objc private func installShell() {
        let result = AgentHub.installShellIntegration()
        let alert = NSAlert()
        alert.messageText = result.ok ? "Терминал подключён" : "Не удалось подключить терминал"
        alert.informativeText = result.message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func installHooks() {
        let result = AgentHub.installHooks()
        model.agents.checkHooks()
        let alert = NSAlert()
        alert.messageText = result.ok ? "Агенты подключены" : "Не удалось подключить агентов"
        alert.informativeText = result.message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

enum LoginItem {
    static let label = "dev.nook.app"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func setEnabled(_ on: Bool) {
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
