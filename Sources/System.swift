import AppKit
import Carbon
import IOKit.ps

// MARK: Global hotkey (Carbon, needs no permission)

enum HotKey {
    static let command = UInt32(cmdKey)
    static let control = UInt32(controlKey)
    static let option = UInt32(optionKey)
    static let shift = UInt32(shiftKey)

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var installed = false

    static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, _ handler: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKey = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                DispatchQueue.main.async { HotKey.handlers[hotKey.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4E4F_4F4B), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref); handlers[id] = handler }
    }
}

// MARK: Battery

final class Battery: ObservableObject {
    @Published private(set) var percent = 0
    @Published private(set) var charging = false
    @Published private(set) var pluggedIn = false
    @Published private(set) var hasBattery = false
    private var timer: Timer?

    func start(onPlug: @escaping (Int) -> Void) {
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let wasPlugged = self.pluggedIn
            self.read()
            if self.hasBattery && self.pluggedIn && !wasPlugged { onPlug(self.percent) }
        }
    }

    private func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
            pluggedIn = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        }
    }
}

// MARK: AI usage limits

struct UsageWindow: Equatable {
    var usedPercent: Double
    var resetsAt: Date?
}

/// Reads limits from local files only; makes no network calls and reads no credentials.
final class Limits: ObservableObject {
    @Published private(set) var claudeSession: UsageWindow?
    @Published private(set) var claudeWeek: UsageWindow?
    @Published private(set) var codexPrimary: UsageWindow?
    @Published private(set) var codexWindowMinutes = 0
    @Published private(set) var claudeUpdated: Date?
    private var timer: Timer?
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let claude = self.readClaude()
            let codex = self.readCodex()
            DispatchQueue.main.async {
                self.claudeSession = claude?.session
                self.claudeWeek = claude?.week
                self.claudeUpdated = claude?.at
                self.codexPrimary = codex?.window
                self.codexWindowMinutes = codex?.minutes ?? 0
            }
        }
    }

    private func readClaude() -> (session: UsageWindow?, week: UsageWindow?, at: Date)? {
        // 1. Status-line relay file (fresh while a Claude Code terminal is open).
        let relay = home.appendingPathComponent(".config/panegrip/claude-limits.json")
        var best: (UsageWindow?, UsageWindow?, Date)?
        if let data = try? Data(contentsOf: relay),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let limits = root["rate_limits"] as? [String: Any] {
            func window(_ key: String) -> UsageWindow? {
                guard let v = limits[key] as? [String: Any], let used = (v["used_percentage"] as? NSNumber)?.doubleValue
                else { return nil }
                let reset = (v["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return UsageWindow(usedPercent: used, resetsAt: reset)
            }
            let at = (root["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
            best = (window("five_hour"), window("seven_day"), at)
        }
        // 2. Claude Code's own cache in ~/.claude.json.
        if let data = try? Data(contentsOf: home.appendingPathComponent(".claude.json")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = root["cachedUsageUtilization"] as? [String: Any],
           let util = cache["utilization"] as? [String: Any] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func window(_ key: String) -> UsageWindow? {
                guard let v = util[key] as? [String: Any], let used = (v["utilization"] as? NSNumber)?.doubleValue
                else { return nil }
                return UsageWindow(usedPercent: used, resetsAt: (v["resets_at"] as? String).flatMap(iso.date(from:)))
            }
            let at = (cache["fetchedAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                ?? .distantPast
            if best == nil || at > best!.2 { best = (window("five_hour"), window("seven_day"), at) }
        }
        guard let best else { return nil }
        // A window whose reset time has passed is empty again.
        func current(_ w: UsageWindow?) -> UsageWindow? {
            guard let w else { return nil }
            if let r = w.resetsAt, r < Date() { return UsageWindow(usedPercent: 0, resetsAt: nil) }
            return w
        }
        return (current(best.0), current(best.1), best.2)
    }

    private func readCodex() -> (window: UsageWindow, minutes: Int)? {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var newest: (URL, Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if newest == nil || date > newest!.1 { newest = (url, date) }
        }
        guard let file = newest?.0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 2_000_000 ? size - 2_000_000 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let limits = Self.find("rate_limits", in: obj) as? [String: Any],
                  let primary = limits["primary"] as? [String: Any],
                  let used = (primary["used_percent"] as? NSNumber)?.doubleValue else { continue }
            var reset = (primary["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            var usedNow = used
            if let r = reset, r < Date() { usedNow = 0; reset = nil }
            return (UsageWindow(usedPercent: usedNow, resetsAt: reset), (primary["window_minutes"] as? Int) ?? 0)
        }
        return nil
    }

    private static func find(_ key: String, in object: Any) -> Any? {
        if let dict = object as? [String: Any] {
            if let value = dict[key], !(value is NSNull) { return value }
            for value in dict.values { if let found = find(key, in: value) { return found } }
        } else if let array = object as? [Any] {
            for value in array { if let found = find(key, in: value) { return found } }
        }
        return nil
    }
}
