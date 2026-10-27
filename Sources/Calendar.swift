import AppKit
import EventKit

enum Settings {
    private static let d = UserDefaults.standard
    static var agentDoneSound: Bool {
        get { d.object(forKey: "agentDoneSound") as? Bool ?? true }
        set { d.set(newValue, forKey: "agentDoneSound") }
    }
    static var agentDoneMinSeconds: Double {
        get { d.object(forKey: "agentDoneMinSeconds") as? Double ?? 15 }
        set { d.set(newValue, forKey: "agentDoneMinSeconds") }
    }
    /// How long a finished agent session stays in the lists (seconds).
    static var finishedSessionTTL: Double {
        get { d.object(forKey: "finishedSessionTTL") as? Double ?? 600 }
        set { d.set(newValue, forKey: "finishedSessionTTL") }
    }
    static var notificationIslands: Bool {
        get { d.object(forKey: "notificationIslands") as? Bool ?? true }
        set { d.set(newValue, forKey: "notificationIslands") }
    }
    /// Show the text of app notifications, not just the app and title. Off by default: the notch ignores
    /// the per-app "Show previews" setting, so message texts and codes would be readable by anyone nearby.
    static var notificationText: Bool {
        get { d.object(forKey: "notificationText") as? Bool ?? false }
        set { d.set(newValue, forKey: "notificationText") }
    }
    /// Keep the notch out of screenshots, recordings and screen sharing.
    static var hideFromCapture: Bool {
        get { d.object(forKey: "hideFromCapture") as? Bool ?? false }
        set { d.set(newValue, forKey: "hideFromCapture") }
    }
    static var mutedApps: Set<String> {
        get { Set(d.stringArray(forKey: "mutedApps") ?? []) }
        set { d.set(Array(newValue), forKey: "mutedApps") }
    }
    /// The display the notch lives on (its UUID); nil follows the built-in display with a camera housing.
    static var screenID: String? {
        get { d.string(forKey: "screenID") }
        set { d.set(newValue, forKey: "screenID") }
    }
    static var showMenuIcon: Bool {
        get { d.object(forKey: "showMenuIcon") as? Bool ?? true }
        set { d.set(newValue, forKey: "showMenuIcon") }
    }
    /// Volume changes shown in the notch (and the volume keys handled by Nook with Accessibility access).
    static var volumeHUD: Bool {
        get { d.object(forKey: "volumeHUD") as? Bool ?? true }
        set { d.set(newValue, forKey: "volumeHUD") }
    }
    static var askedKeyAccess: Bool {
        get { d.bool(forKey: "askedKeyAccess") }
        set { d.set(newValue, forKey: "askedKeyAccess") }
    }
    static var focusHUD: Bool {
        get { d.object(forKey: "focusHUD") as? Bool ?? true }
        set { d.set(newValue, forKey: "focusHUD") }
    }
    static var autoUpdate: Bool {
        get { d.object(forKey: "autoUpdate") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoUpdate") }
    }
    /// Agents whose hooks Nook already connected by itself once ("claude", "codex"): if the person later
    /// removes them, Nook does not put them back on its own.
    static var hooksAutoConnected: Set<String> {
        get { Set(d.stringArray(forKey: "hooksAutoConnected") ?? []) }
        set { d.set(Array(newValue), forKey: "hooksAutoConnected") }
    }
}

/// Today's and tomorrow's events plus open reminders, from the system Calendar and Reminders.
final class CalendarStore: ObservableObject {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: NSColor
        let location: String?
        let meetingURL: URL?
    }

    struct Reminder: Identifiable, Equatable {
        let id: String
        let title: String
        let due: Date?
        let list: String
        let color: NSColor
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var reminders: [Reminder] = []
    @Published private(set) var calendarAccess = false
    @Published private(set) var remindersAccess = false
    @Published private(set) var asked = false

    private let store = EKEventStore()
    private var timer: Timer?
    private var announced = Set<String>()
    private var onIsland: ((Island) -> Void)?

    var nextEvent: Event? {
        let now = Date()
        return events.first { !$0.allDay && $0.end > now }
    }

    func start(onIsland: @escaping (Island) -> Void) {
        self.onIsland = onIsland
        updateAccess()
        reload()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.reload()
        }
        // Events reload every 5 min and on every Calendar change; the 5-minute-warning check is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastReload) > 300 { self.reload() }
            self.announceUpcoming()
        }
        timer?.tolerance = 5
    }

    private func updateAccess() {
        calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        remindersAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        asked = EKEventStore.authorizationStatus(for: .event) != .notDetermined
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] _, _ in
            self?.store.requestFullAccessToReminders { _, _ in
                DispatchQueue.main.async {
                    // A store created before the grant may not list calendars until it refreshes.
                    self?.store.refreshSourcesIfNecessary()
                    self?.updateAccess()
                    self?.reload()
                    if self?.calendarAccess == false {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
        }
    }

    private var lastReload = Date.distantPast
    private let queue = DispatchQueue(label: "nook.calendar")

    func reload() {
        updateAccess()
        lastReload = Date()
        if calendarAccess {
            // EventKit fetch and link detection in notes run off the main thread.
            let store = store
            queue.async { [weak self] in
                let start = Calendar.current.startOfDay(for: Date())
                let end = Calendar.current.date(byAdding: .day, value: 2, to: start)!
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
                let found = store.events(matching: predicate)
                    .filter { $0.endDate > Date() || $0.isAllDay }
                    .sorted { $0.startDate < $1.startDate }
                    .prefix(30)
                    .map { e in
                        Event(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Без названия",
                              start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                              color: e.calendar.color ?? .systemBlue, location: e.location,
                              meetingURL: Self.meetingURL(in: [e.url?.absoluteString, e.location, e.notes]))
                    }
                DispatchQueue.main.async { if self?.events != Array(found) { self?.events = Array(found) } }
            }
        }
        if remindersAccess {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { [weak self] items in
                let list = (items ?? [])
                    .sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
                    .prefix(40)
                    .map { r in
                        Reminder(id: r.calendarItemIdentifier, title: r.title ?? "", due: r.dueDateComponents?.date,
                                 list: r.calendar.title, color: r.calendar.color ?? .systemOrange)
                    }
                DispatchQueue.main.async { self?.reminders = Array(list) }
            }
        }
    }

    func complete(_ reminder: Reminder) {
        guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
        item.isCompleted = true
        try? store.save(item, commit: true)
        reminders.removeAll { $0.id == reminder.id }
    }

    func addReminder(_ title: String) {
        let text = title.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, remindersAccess, let list = store.defaultCalendarForNewReminders() else { return }
        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        try? store.save(reminder, commit: true)
        reload()
    }

    func openCalendar() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }

    /// One island five minutes before each timed event.
    private func announceUpcoming() {
        let now = Date()
        for event in events where !event.allDay && !announced.contains(event.id) {
            let lead = event.start.timeIntervalSince(now)
            if lead > 0 && lead <= 5 * 60 + 15 {
                announced.insert(event.id)
                onIsland?(Island(kind: .event(title: event.title, start: event.start, url: event.meetingURL), seconds: 10))
            }
        }
    }

    private static func meetingURL(in fields: [String?]) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for case let text? in fields {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                // The exact host or a subdomain of it, over https: "evilzoom.us" is not Zoom.
                if let url = match.url, url.scheme == "https", let host = url.host?.lowercased(),
                   hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }
}
