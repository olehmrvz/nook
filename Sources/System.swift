import AppKit
import Carbon
import IOKit
import IOKit.ps
import SwiftUI

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
    @Published private(set) var minutesToFull: Int?
    @Published private(set) var minutesToEmpty: Int?
    /// Full-charge capacity against design capacity, like "Maximum Capacity" in Settings.
    @Published private(set) var health: Int?
    @Published private(set) var cycles: Int?
    /// Plugged in but not charging below 100 %: the macOS charge limit or Optimized Charging holds it.
    @Published private(set) var held = false
    private var timer: Timer?
    private var detailsRead = Date.distantPast

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
            set(\.hasBattery, true)
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            set(\.percent, max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current)
            set(\.charging, d[kIOPSIsChargingKey] as? Bool ?? false)
            set(\.pluggedIn, d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            let full = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            let empty = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            set(\.minutesToFull, charging && full > 0 ? full : nil)
            set(\.minutesToEmpty, !pluggedIn && empty > 0 ? empty : nil)
        }
        if Date().timeIntervalSince(detailsRead) > 30 { readDetails() }
        set(\.held, hasBattery && pluggedIn && !charging && percent < 100)
    }

    /// Health and cycles from the battery's registry entry (no special permission needed).
    private func readDetails() {
        detailsRead = Date()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return }
        let data = dict["BatteryData"] as? [String: Any] ?? [:]
        let design = data["DesignCapacity"] as? Int ?? dict["DesignCapacity"] as? Int
        let nominal = data["NominalChargeCapacity"] as? Int ?? dict["NominalChargeCapacity"] as? Int
        if let design, let nominal, design > 0 {
            set(\.health, min(100, Int((Double(nominal) / Double(design) * 100).rounded())))
        }
        set(\.cycles, dict["CycleCount"] as? Int)
    }

    /// Assigns only real changes, so the panel does not redraw every three seconds.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<Battery, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    var headline: String {
        if held { return "Держу заряд" }
        if charging { return "Заряжается" }
        if pluggedIn { return "От сети" }
        return "От батареи"
    }

    var tint: Color {
        if held || charging || pluggedIn { return Palette.green }
        return percent <= 20 ? Palette.red : Color.white.opacity(0.75)
    }

    var detail: String {
        if held { return "Адаптер подключён, зарядка на паузе: работает лимит заряда или оптимизированная зарядка." }
        if let m = minutesToFull { return "Полная зарядка через " + Format.span(Double(m) * 60) + "." }
        if let m = minutesToEmpty { return "Хватит примерно на " + Format.span(Double(m) * 60) + "." }
        return pluggedIn ? "Адаптер подключён." : "Считаю оставшееся время…"
    }

    static func openChargeLimitSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Battery-Settings.extension",
                    "x-apple.systempreferences:com.apple.preference.battery"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
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

    /// One read at a time: overlapping refreshes would race on the Codex cache.
    private let queue = DispatchQueue(label: "nook.limits", qos: .utility)

    func refresh() {
        queue.async { [weak self] in
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

    private var codexCache: (path: String, modified: Date, result: (window: UsageWindow, minutes: Int)?)?

    /// Newest session file. Sessions live in YYYY/MM/DD folders, so walk down the latest names
    /// instead of listing hundreds of files every 30 s; fall back to a full scan for other layouts.
    private func newestCodexFile(in root: URL) -> (URL, Date)? {
        let fm = FileManager.default
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        }
        var dir = root
        for _ in 0..<3 {
            guard let last = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter({ !$0.hasPrefix(".") }).sorted().last
            else { break }
            dir = dir.appendingPathComponent(last)
        }
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        if let best = files.map({ ($0, modified($0)) }).max(by: { $0.1 < $1.1 }) { return best }
        var newest: (URL, Date)?
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            let date = modified(url)
            if newest == nil || date > newest!.1 { newest = (url, date) }
        }
        return newest
    }

    private func readCodex() -> (window: UsageWindow, minutes: Int)? {
        let root = home.appendingPathComponent(".codex/sessions")
        guard let newest = newestCodexFile(in: root) else { return nil }
        // Same file, untouched since the last read: the answer cannot have changed (only a passed reset can).
        if let cache = codexCache, cache.path == newest.0.path, cache.modified == newest.1,
           cache.result?.window.resetsAt.map({ $0 > Date() }) ?? true {
            return cache.result
        }
        let result = readCodexFile(newest.0)
        codexCache = (newest.0.path, newest.1, result)
        return result
    }

    private func readCodexFile(_ file: URL) -> (window: UsageWindow, minutes: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
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
