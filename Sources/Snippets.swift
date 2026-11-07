import AppKit
import Carbon.HIToolbox

/// Text into the app in front: typed as keys (short, one line) or pasted through the clipboard, which gets its
/// content back afterwards. Nook's own events carry `tag`, so the snippet watcher does not read them as typing.
enum TextInsertion {
    static let tag: Int64 = 0x4E4F_4F4B
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    /// The pasted text sits in the clipboard until the old content is back (no restart for an update meanwhile).
    private(set) static var restoring = false

    static func paste(_ text: String, into target: NSRunningApplication? = nil, then done: (() -> Void)? = nil) {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transient)
        board.clearContents()
        board.writeObjects([item])
        let ours = board.changeCount
        restoring = true
        var delay = 0.0
        if let target, !target.isTerminated, NSWorkspace.shared.frontmostApplication != target {
            target.activate()
            delay = 0.1
        }
        // ⌘V only once the app is in front (another Space, a busy app can take a while): else it would land in the
        // app you switched to. It never came: the text stays on the clipboard to paste by hand.
        func pasteWhenFront(waited: Double) {
            if let target, !target.isTerminated, NSWorkspace.shared.frontmostApplication != target {
                guard waited < 1 else { restoring = false; done?(); return }
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { pasteWhenFront(waited: waited + 0.03) }
            }
            NotchModel.sendPaste()
            // A busy app reads the clipboard late: putting the old one back too soon would paste that instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                restoring = false
                // Copied something else meanwhile: keep that.
                if board.changeCount == ours {
                    saved.forEach { $0.setData(Data(), forType: transient) }
                    board.clearContents()
                    if !saved.isEmpty { board.writeObjects(saved) }
                }
                done?()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { pasteWhenFront(waited: delay) }
    }

    /// Unicode key events, at most 4 UTF-16 units each (Chromium drops longer ones), never splitting a pair.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + 4, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[i..<end])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event?.setIntegerValueField(.eventSourceUserData, value: tag)
                event?.post(tap: .cghidEventTap)
            }
            i = end
        }
    }

    static func press(_ key: Int, times: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<times {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
                event?.setIntegerValueField(.eventSourceUserData, value: tag)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Short single-line text is typed (no clipboard round trip); the rest is pasted.
    static func insert(_ text: String) {
        if text.count <= 100, !text.contains("\n") { type(text) } else { paste(text) }
    }
}

extension Settings {
    /// Typing a keyword expands it in any app (needs Accessibility). Off until switched on.
    static var snippets: Bool {
        get { UserDefaults.standard.bool(forKey: "snippets") }
        set { UserDefaults.standard.set(newValue, forKey: "snippets") }
    }
}

/// One snippet: a Markdown file with an optional front matter (name, keyword, enabled).
struct Snippet: Identifiable, Equatable {
    var id: URL { file }
    var file: URL
    var name: String
    var keyword: String
    var enabled = true
    var text: String

    static let folder = supportDir.appendingPathComponent("Snippets", isDirectory: true)

    init(file: URL, name: String, keyword: String, enabled: Bool = true, text: String) {
        self.file = file
        self.name = name
        self.keyword = keyword
        self.enabled = enabled
        self.text = text
    }

    /// `---` / `name: "…"` / `keyword: "…"` / `enabled: true` / `---` / body. No front matter: all body.
    init?(file: URL) {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        self.file = file
        name = file.deletingPathExtension().lastPathComponent
        keyword = ""
        text = raw
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return }
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            switch key {
            case "name": name = value
            case "keyword": keyword = value
            case "enabled": enabled = value != "false"
            default: break
            }
        }
        var body = lines[(end + 1)...]
        if body.first == "" { body = body.dropFirst() }
        text = body.joined(separator: "\n")
    }

    var fileText: String {
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "---\nname: \(quoted(name))\nkeyword: \(quoted(keyword))\nenabled: \(enabled)\n---\n\n\(text)"
    }
}

/// Snippets on disk, keyword expansion while typing, placeholders.
final class Snippets: ObservableObject {
    @Published private(set) var all: [Snippet] = []

    /// Recent clipboard texts for `{clipboard offset=N}`; set by the model.
    var clipboardHistory: () -> [String] = { [] }

    private let io = DispatchQueue(label: "nook.snippets")
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var buffer = ""
    private var lastKey = Date.distantPast
    private var appObserver: NSObjectProtocol?

    func start() {
        load()
        apply()
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.buffer = ""
        }
    }

    func load() {
        io.async { [weak self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: Snippet.folder, withIntermediateDirectories: true)
            let files = (try? fm.contentsOfDirectory(at: Snippet.folder, includingPropertiesForKeys: nil)) ?? []
            let snippets = files.filter { $0.pathExtension == "md" }.compactMap(Snippet.init(file:))
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self?.all = snippets }
        }
    }

    /// A new file for a new snippet: its name, made unique.
    func save(_ snippet: Snippet, replacing old: Snippet?) {
        var snippet = snippet
        io.async { [weak self] in
            let fm = FileManager.default
            try? fm.createDirectory(at: Snippet.folder, withIntermediateDirectories: true)
            if old == nil || old?.name != snippet.name {
                let base = snippet.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                var url = Snippet.folder.appendingPathComponent("\(base.isEmpty ? "Сниппет" : base).md")
                var n = 2
                while fm.fileExists(atPath: url.path), url != old?.file {
                    url = Snippet.folder.appendingPathComponent("\(base) \(n).md")
                    n += 1
                }
                if let old, old.file != url { try? fm.removeItem(at: old.file) }
                snippet.file = url
            }
            try? snippet.fileText.write(to: snippet.file, atomically: true, encoding: .utf8)
            self?.load()
        }
    }

    func delete(_ snippet: Snippet) {
        io.async { [weak self] in
            try? FileManager.default.trashItem(at: snippet.file, resultingItemURL: nil)
            self?.load()
        }
    }

    // MARK: Keywords

    /// A listening tap while snippets are on and Accessibility is given; typing never waits for it.
    func apply() {
        if Settings.snippets && AXIsProcessTrusted() { installTap() } else { removeTap() }
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let snippets = Unmanaged<Snippets>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = snippets.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if event.getIntegerValueField(.eventSourceUserData) != TextInsertion.tag {
                snippets.typed(event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        buffer = ""
    }

    /// Kept in memory only, at most 256 characters, never logged.
    private func typed(_ event: CGEvent) {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        // Shortcuts, navigation and 15 s of quiet start over; a password field is never read.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || IsSecureEventInputEnabled()
            || [kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ANSI_KeypadEnter].contains(code)
            || Date().timeIntervalSince(lastKey) > 15 {
            buffer = ""
            lastKey = Date()
            if flags.contains(.maskCommand) || flags.contains(.maskControl) || code == kVK_Return || code == kVK_Tab { return }
        }
        lastKey = Date()
        if code == kVK_Delete {
            if !buffer.isEmpty { buffer.removeLast() }
            return
        }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        buffer += String(utf16CodeUnits: chars, count: length)
        if buffer.count > 256 { buffer.removeFirst(buffer.count - 256) }
        let typed = buffer.lowercased()
        // The longest keyword that ends the typing wins.
        guard let match = all.filter({ $0.enabled && !$0.keyword.isEmpty && typed.hasSuffix($0.keyword.lowercased()) })
            .max(by: { $0.keyword.count < $1.keyword.count }) else { return }
        let seen = buffer
        // Next turn of the main loop: the keystroke reaches the app first; more typing cancels it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.buffer == seen, !IsSecureEventInputEnabled(), AXIsProcessTrusted() else { return }
            self.buffer = ""
            TextInsertion.press(kVK_Delete, times: match.keyword.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { self.insert(match) }
        }
    }

    /// Expanded text in, the caret on `{cursor}` if there is one.
    func insert(_ snippet: Snippet) {
        let expanded = expand(snippet.text)
        guard let mark = expanded.range(of: Self.cursorMark) else { return TextInsertion.insert(expanded) }
        let back = expanded[mark.upperBound...].count
        TextInsertion.insert(expanded.replacingOccurrences(of: Self.cursorMark, with: ""))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { TextInsertion.press(kVK_LeftArrow, times: back) }
    }

    // MARK: Placeholders

    private static let cursorMark = "\u{E000}"

    /// Raycast-style: {clipboard}, {clipboard offset=1}, {date}, {time}, {datetime}, {day}, {uuid}, {cursor},
    /// {date format="dd.MM.yyyy"}, {time offset="+3h +30m"}. Unknown tokens stay as they are; values are not expanded again.
    func expand(_ template: String) -> String {
        var result = ""
        var rest = Substring(template)
        var cursorUsed = false
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let token = String(rest[rest.index(after: open)..<close])
            if token == "cursor" {
                result += cursorUsed ? "" : Self.cursorMark
                cursorUsed = true
            } else {
                result += value(token) ?? "{\(token)}"
            }
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    private func value(_ token: String) -> String? {
        let parts = token.split(separator: " ", maxSplits: 1)
        guard let name = parts.first.map(String.init) else { return nil }
        var options: [String: String] = [:]
        if parts.count > 1 {
            // key="value" or key=value pairs.
            let scanner = String(parts[1])
            let pattern = try? NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"]*)"|(\S+))"#)
            for match in pattern?.matches(in: scanner, range: NSRange(scanner.startIndex..., in: scanner)) ?? [] {
                guard let key = Range(match.range(at: 1), in: scanner).map({ String(scanner[$0]) }) else { continue }
                let value = Range(match.range(at: 2), in: scanner) ?? Range(match.range(at: 3), in: scanner)
                options[key] = value.map { String(scanner[$0]) } ?? ""
            }
        }
        let date = options["offset"].flatMap(Self.offset) ?? Date()
        let locale = options["locale"].map(Locale.init(identifier:)) ?? .current
        func formatted(_ style: (Date) -> String) -> String {
            if let format = options["format"] {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.dateFormat = format
                return formatter.string(from: date)
            }
            return style(date)
        }
        switch name {
        case "clipboard":
            let index = Int(options["offset"] ?? "0") ?? 0
            if index == 0 { return NSPasteboard.general.string(forType: .string) ?? "" }
            let history = clipboardHistory()
            return history.indices.contains(index) ? history[index] : ""
        case "date": return formatted { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)) }
        case "time": return formatted { $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)) }
        case "datetime": return formatted { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)) }
        case "day": return formatted { $0.formatted(Date.FormatStyle().weekday(.wide).locale(locale)) }
        case "uuid": return UUID().uuidString
        default: return nil
        }
    }

    /// "+3h +30m", "-1d": signed amounts of m, h, d, M (months), y.
    private static func offset(_ text: String) -> Date? {
        var date = Date()
        let calendar = Calendar.current
        for part in text.split(separator: " ") {
            guard let unit = part.last, let amount = Int(part.dropLast()) else { return nil }
            let component: Calendar.Component? = switch unit {
            case "m": .minute
            case "h": .hour
            case "d": .day
            case "M": .month
            case "y": .year
            default: nil
            }
            guard let component, let next = calendar.date(byAdding: component, value: amount, to: date) else { return nil }
            date = next
        }
        return date
    }
}
