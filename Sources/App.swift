import AppKit
import SwiftUI

let supportDir: URL = {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Nook", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        menu.addItem(withTitle: "Открыть буфер обмена  ⌃⌘V", action: #selector(openClipboard), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Запускать при входе", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        let paste = menu.addItem(withTitle: "Автовставка из буфера (Универсальный доступ)…", action: #selector(askAccessibility), keyEquivalent: "")
        paste.target = self
        let hooks = menu.addItem(withTitle: "Подключить Claude Code и Codex", action: #selector(installHooks), keyEquivalent: "")
        hooks.target = self
        let shell = menu.addItem(withTitle: "Острова для долгих команд (zsh)…", action: #selector(installShell), keyEquivalent: "")
        shell.target = self
        let sound = menu.addItem(withTitle: "Звук, когда агент закончил", action: #selector(toggleAgentSound(_:)), keyEquivalent: "")
        sound.target = self
        sound.state = Settings.agentDoneSound ? .on : .off
        let islands = menu.addItem(withTitle: "Уведомления приложений в вырезе", action: #selector(toggleNotificationIslands(_:)), keyEquivalent: "")
        islands.target = self
        islands.state = Settings.notificationIslands ? .on : .off
        let disk = menu.addItem(withTitle: "Полный доступ к диску (для уведомлений)…", action: #selector(openDiskAccess), keyEquivalent: "")
        disk.target = self
        let capture = menu.addItem(withTitle: "Скрывать Nook при показе экрана", action: #selector(toggleHideFromCapture(_:)), keyEquivalent: "")
        capture.target = self
        capture.state = Settings.hideFromCapture ? .on : .off
        let unmute = menu.addItem(withTitle: "Снова показывать скрытые приложения", action: #selector(unmuteApps), keyEquivalent: "")
        unmute.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти из Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openClipboard() { model.toggleClipboardFromHotkey() }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        LoginItem.setEnabled(!LoginItem.isEnabled)
        sender.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggleAgentSound(_ sender: NSMenuItem) {
        Settings.agentDoneSound.toggle()
        sender.state = Settings.agentDoneSound ? .on : .off
    }

    @objc private func toggleNotificationIslands(_ sender: NSMenuItem) {
        Settings.notificationIslands.toggle()
        sender.state = Settings.notificationIslands ? .on : .off
    }

    @objc private func toggleHideFromCapture(_ sender: NSMenuItem) {
        Settings.hideFromCapture.toggle()
        sender.state = Settings.hideFromCapture ? .on : .off
        panel.sharingType = Settings.hideFromCapture ? .none : .readOnly
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
        alert.messageText = result.ok ? "Хуки подключены" : "Не удалось подключить хуки"
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
