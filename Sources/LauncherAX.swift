import AppKit

/// The menu bar of the app in front, read once when the search opens (Accessibility). Never opens a menu.
enum MenuSearch {
    struct Item: Equatable {
        /// "Файл → Экспортировать…" without the last part: the menu it lives in.
        let path: [String]
        let title: String
        /// "⇧⌘S" or empty.
        let keys: String
        let element: AXUIElement
    }

    /// Off the main thread; stops after `limit` items or `seconds`.
    static func items(of pid: pid_t, limit: Int = 4000, seconds: TimeInterval = 1) -> [Item] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let bar: AXUIElement = value(app, kAXMenuBarAttribute) else { return [] }
        let deadline = Date().addingTimeInterval(seconds)
        var result: [Item] = []
        // The first menu is Apple's own.
        for top in children(bar).dropFirst() {
            guard let name: String = value(top, kAXTitleAttribute), !name.isEmpty else { continue }
            for menu in children(top) { walk(menu, path: [name], into: &result, limit: limit, deadline: deadline) }
            if result.count >= limit || Date() > deadline { break }
        }
        return result
    }

    private static func walk(_ menu: AXUIElement, path: [String], into result: inout [Item], limit: Int, deadline: Date) {
        for item in children(menu) {
            guard result.count < limit, Date() < deadline else { return }
            guard let title: String = value(item, kAXTitleAttribute), !title.isEmpty else { continue }
            let submenus = children(item)
            if !submenus.isEmpty {
                for submenu in submenus { walk(submenu, path: path + [title], into: &result, limit: limit, deadline: deadline) }
                continue
            }
            guard (value(item, kAXEnabledAttribute) as Bool?) ?? false else { continue }
            result.append(Item(path: path, title: title, keys: keys(item), element: item))
        }
    }

    static func press(_ item: Item) {
        DispatchQueue.global(qos: .userInitiated).async { AXUIElementPerformAction(item.element, kAXPressAction as CFString) }
    }

    /// AXMenuItemCmdModifiers: 0 = ⌘; 1 ⇧, 2 ⌥, 4 ⌃, 8 = without ⌘.
    private static func keys(_ item: AXUIElement) -> String {
        guard let char: String = value(item, kAXMenuItemCmdCharAttribute), !char.isEmpty else { return "" }
        let mods = (value(item, kAXMenuItemCmdModifiersAttribute) as Int?) ?? 0
        var text = ""
        if mods & 4 != 0 { text += "⌃" }
        if mods & 2 != 0 { text += "⌥" }
        if mods & 1 != 0 { text += "⇧" }
        if mods & 8 == 0 { text += "⌘" }
        // Control characters stand for keys: delete, escape, return, tab.
        let named: [String: String] = ["\u{08}": "⌫", "\u{7F}": "⌦", "\u{1B}": "⎋", "\r": "↩", "\u{03}": "⌤", "\t": "⇥", " ": "Пробел"]
        return text + (named[char] ?? char.uppercased())
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }
}

/// Open windows of the running apps, for "switch to a window" from the search (Accessibility).
enum WindowList {
    struct Window: Equatable {
        let title: String
        let app: String
        let pid: pid_t
        let bundle: URL?
        let element: AXUIElement
        let minimized: Bool
    }

    /// Off the main thread; each app may answer for 0.2 s at most.
    static func all() -> [Window] {
        let own = ProcessInfo.processInfo.processIdentifier
        var result: [Window] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != own {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.2)
            for window in (MenuSearch.value(element, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
                guard let title: String = MenuSearch.value(window, kAXTitleAttribute), !title.isEmpty,
                      (MenuSearch.value(window, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole as String else { continue }
                let minimized = (MenuSearch.value(window, kAXMinimizedAttribute) as Bool?) ?? false
                result.append(Window(title: title, app: app.localizedName ?? "", pid: app.processIdentifier,
                                     bundle: app.bundleURL, element: window, minimized: minimized))
            }
        }
        return result
    }

    static func raise(_ window: Window) {
        DispatchQueue.global(qos: .userInitiated).async {
            if window.minimized { AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            DispatchQueue.main.async { NSRunningApplication(processIdentifier: window.pid)?.activate() }
        }
    }
}
