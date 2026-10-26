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
            let tab = command.isEmpty ? "home" : command
            DistributedNotificationCenter.default().postNotificationName(
                .init("dev.nook.show"), object: tab, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        // `Nook --answer allow|always|deny|terminal` answers the oldest pending agent request.
        if let i = CommandLine.arguments.firstIndex(of: "--answer") {
            let answer = CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "allow"
            DistributedNotificationCenter.default().postNotificationName(
                .init("dev.nook.answer"), object: answer, userInfo: nil, deliverImmediately: true)
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
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.nook.show"), object: nil,
                                                            queue: .main) { [weak self] note in
            guard let self else { return }
            let name = note.object as? String ?? "home"
            if name == "close" { self.model.collapse(); self.model.cuely.stop(); return }
            if name == "prompt" { self.model.cuely.present(); self.model.focusPanel(); return }
            if name.hasPrefix("timer:"), let minutes = Double(name.dropFirst(6)) {
                self.model.timer.pomodoro = false
                self.model.timer.start(minutes: minutes)
                return
            }
            if name == "pomodoro" { self.model.timer.startPomodoro(); return }
            if name == "timer-stop" { self.model.timer.reset(); return }
            self.model.open(tab: Tab(rawValue: name) ?? .home)
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.nook.answer"), object: nil,
                                                            queue: .main) { [weak self] note in
            guard let agents = self?.model.agents, let oldest = agents.permissions.first else { return }
            let decision: AgentHub.Decision? = switch note.object as? String {
            case "allow": .allow
            case "always": .always
            case "deny": .deny
            default: nil
            }
            agents.answer(oldest.id, with: decision)
        }
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
        let sound = menu.addItem(withTitle: "Звук, когда агент закончил", action: #selector(toggleAgentSound(_:)), keyEquivalent: "")
        sound.target = self
        sound.state = Settings.agentDoneSound ? .on : .off
        let islands = menu.addItem(withTitle: "Уведомления приложений в вырезе", action: #selector(toggleNotificationIslands(_:)), keyEquivalent: "")
        islands.target = self
        islands.state = Settings.notificationIslands ? .on : .off
        let disk = menu.addItem(withTitle: "Полный доступ к диску (для уведомлений)…", action: #selector(openDiskAccess), keyEquivalent: "")
        disk.target = self
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

    @objc private func openDiskAccess() { NotificationWatcher.openSettings() }
    @objc private func unmuteApps() { Settings.mutedApps = [] }

    @objc private func askAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @objc private func installHooks() {
        let result = AgentHub.installHooks()
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
