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
    static var notificationIslands: Bool {
        get { d.object(forKey: "notificationIslands") as? Bool ?? true }
        set { d.set(newValue, forKey: "notificationIslands") }
    }
    static var mutedApps: Set<String> {
        get { Set(d.stringArray(forKey: "mutedApps") ?? []) }
        set { d.set(Array(newValue), forKey: "mutedApps") }
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
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.reload()
            self?.announceUpcoming()
        }
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
                    self?.updateAccess()
                    self?.reload()
                    if self?.calendarAccess == false {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                    }
                }
            }
        }
    }

    func reload() {
        updateAccess()
        if calendarAccess {
            let start = Calendar.current.startOfDay(for: Date())
            let end = Calendar.current.date(byAdding: .day, value: 2, to: start)!
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            events = store.events(matching: predicate)
                .filter { $0.endDate > Date() || $0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
                .prefix(30)
                .map { e in
                    Event(id: e.eventIdentifier ?? UUID().uuidString, title: e.title ?? "Без названия",
                          start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                          color: e.calendar.color ?? .systemBlue, location: e.location,
                          meetingURL: Self.meetingURL(in: [e.url?.absoluteString, e.location, e.notes]))
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
                if let url = match.url, let host = url.host, hosts.contains(where: { host.hasSuffix($0) }) { return url }
            }
        }
        return nil
    }
}
