import AppKit
import SwiftUI

// MARK: Calendar (Figma «H · Календарь»: what is next in large type, the day, tomorrow and reminders as tiles)

struct CalendarTab: View {
    @ObservedObject var store: CalendarStore
    @State private var newReminder = ""

    var body: some View {
        if !store.calendarAccess && !store.remindersAccess {
            Tile {
                VStack(spacing: 10) {
                    TileIcon(symbol: "calendar.badge.plus", color: Tone.meeting, size: 44)
                    Text("Покажу события и напоминания прямо в вырезе").font(.system(size: 15, weight: .semibold))
                    Button(store.asked ? L("Открыть настройки доступа") : L("Разрешить доступ")) { store.requestAccess() }
                        .buttonStyle(.pill(.primary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .entrance(0)
        } else {
            GeometryReader { geo in
                let col = (geo.size.width - 3 * Spacing.gap) / 4
                let row = (geo.size.height - Spacing.gap) / 2
                HStack(alignment: .top, spacing: Spacing.gap) {
                    VStack(spacing: Spacing.gap) {
                        HStack(spacing: Spacing.gap) {
                            next.frame(width: 2 * col + Spacing.gap).entrance(0)
                            date.frame(width: col).entrance(1)
                        }
                        .frame(height: row)
                        HStack(spacing: Spacing.gap) {
                            today.frame(width: col).entrance(3)
                            tomorrow.frame(width: 2 * col + Spacing.gap).entrance(4)
                        }
                        .frame(height: row)
                    }
                    reminders.frame(width: col).entrance(2)
                }
            }
            .animation(Motion.smooth, value: store.events.map(\.id))
            .animation(Motion.smooth, value: store.reminders.map(\.id))
        }
    }

    private var todayEvents: [CalendarStore.Event] { store.events.filter { Calendar.current.isDateInToday($0.start) || ($0.start < Date() && $0.end > Date()) } }
    private var tomorrowEvents: [CalendarStore.Event] { store.events.filter { Calendar.current.isDateInTomorrow($0.start) } }

    // MARK: Tiles

    /// What comes next, in large type, with the way in.
    private var next: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                if !store.calendarAccess {
                    TileHeader(symbol: "calendar", color: Tone.meeting, title: L("Дальше"))
                    Text("Покажу встречи").font(.system(size: 17, weight: .bold)).padding(.top, 9)
                    Text("Нужен доступ к Календарю").font(.system(size: 11.5)).foregroundStyle(muted).padding(.top, 2)
                    Spacer(minLength: 0)
                    Button(store.asked ? L("Открыть настройки доступа") : L("Разрешить")) { store.requestAccess() }
                        .buttonStyle(.pill(.ghost, small: true))
                } else if let e = store.nextEvent {
                    HStack(spacing: 8) {
                        TileIcon(symbol: "calendar", color: Tone.meeting, size: 22)
                        Caps(text: Self.lead(e), color: Tone.meeting)
                    }
                    Text(e.title).font(.system(size: 17, weight: .bold)).tracking(-0.3).lineLimit(1).padding(.top, 9)
                    Text(Self.span(e)).font(.system(size: 11.5)).foregroundStyle(muted).lineLimit(1).padding(.top, 2)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        if let url = e.meetingURL {
                            Button("Подключиться") { NSWorkspace.shared.open(url) }.buttonStyle(.pill(.go, small: true))
                                .help(L("Подключиться: ") + Meeting.name(url))
                        }
                        Button(L("Календарь ↗")) { store.openCalendar() }.buttonStyle(.pill(.ghost, small: true))
                    }
                } else {
                    TileHeader(symbol: "calendar", color: Tone.meeting, title: L("Дальше"))
                    Text("Сегодня больше ничего").font(.system(size: 17, weight: .bold)).padding(.top, 9)
                    Spacer(minLength: 0)
                    Button(L("Календарь ↗")) { store.openCalendar() }.buttonStyle(.pill(.ghost, small: true))
                }
            }
        }
    }

    /// Today's date the way a paper calendar shows it.
    private var date: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    TileIcon(symbol: "calendar", color: Tone.deny)
                    Text(Date().formatted(.dateTime.weekday(.wide)).uppercased())
                        .font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(Color(hex: 0xFF8A80)).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Date().formatted(.dateTime.day())).font(.rounded(40, .heavy))
                    Text(Self.month.string(from: Date())).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
                Text([store.calendarAccess ? Format.count(todayEvents.count, "событие", "события", "событий") : nil,
                      store.remindersAccess ? Format.count(store.reminders.count, "напоминание", "напоминания", "напоминаний") : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(muted).lineLimit(1)
            }
        }
    }

    private var today: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                Caps(text: L("Сегодня"))
                if todayEvents.isEmpty {
                    Text(store.calendarAccess ? L("Свободно") : "—").font(.system(size: 12)).foregroundStyle(muted).padding(.top, 8)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(todayEvents) { e in
                                HStack(spacing: 8) {
                                    Circle().fill(Color(nsColor: e.color)).frame(width: 7, height: 7)
                                    Text(e.allDay ? L("весь день") : e.start.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                                    Text(e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                }
                                .frame(height: 24)
                                .opacity(e.end < Date() ? 0.5 : 1)
                            }
                        }
                    }
                    .defaultScrollAnchor(.top)
                    .padding(.top, 6)
                }
            }
        }
    }

    private var tomorrow: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Caps(text: L("Завтра · ") + Date().addingTimeInterval(86400).formatted(.dateTime.weekday(.wide)))
                    Spacer()
                    if !tomorrowEvents.isEmpty {
                        Text(Format.count(tomorrowEvents.count, "событие", "события", "событий"))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                    }
                }
                if tomorrowEvents.isEmpty {
                    Text(store.calendarAccess ? L("Пока ничего") : "—").font(.system(size: 12)).foregroundStyle(muted).padding(.top, 8)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tomorrowEvents) { e in
                                HStack(spacing: 10) {
                                    Text(e.allDay ? L("день") : e.start.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                                        .frame(width: 38, alignment: .leading)
                                    RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.color)).frame(width: 3, height: 26)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(e.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                        Text(Self.span(e)).font(.system(size: 10.5)).foregroundStyle(muted).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(height: 34)
                            }
                        }
                    }
                    .defaultScrollAnchor(.top)
                    .padding(.top, 6)
                }
            }
        }
    }

    private var reminders: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                TileHeader(symbol: "checkmark", color: Tone.ink, title: L("Напоминания"))
                if !store.remindersAccess {
                    Text("Нет доступа к Напоминаниям").font(.system(size: 12)).foregroundStyle(muted).padding(.top, 10)
                    Spacer(minLength: 0)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(store.reminders) { r in
                                HStack(spacing: 9) {
                                    Button { store.complete(r) } label: {
                                        Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(.white.opacity(0.45))
                                    }
                                    .buttonStyle(.icon)
                                    .help("Выполнено")
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(r.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        if let due = r.due {
                                            Text(due.formatted(.relative(presentation: .named)))
                                                .font(.system(size: 10.5)).foregroundStyle(due < Date() ? Tone.deny : muted).lineLimit(1)
                                        }
                                    }
                                }
                                .frame(height: 40, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
                            }
                        }
                    }
                    .defaultScrollAnchor(.top)
                    .padding(.top, 4)
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                        TextField("Новое напоминание", text: $newReminder)
                            .textFieldStyle(.plain).font(.system(size: 11.5))
                            .onSubmit { store.addReminder(newReminder); newReminder = "" }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    // MARK: Words

    /// The month as it follows a day number: "ноября", not "ноябрь".
    private static let month: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMd")
        f.dateFormat = f.dateFormat.replacingOccurrences(of: "d", with: "").trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        return f
    }()

    /// "Через 25 мин · 18:30", "Идёт · до 19:00", "Завтра в 10:00".
    static func lead(_ e: CalendarStore.Event) -> String {
        let start = e.start.formatted(date: .omitted, time: .shortened)
        if e.start <= Date() { return L("Идёт · до ") + e.end.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInToday(e.start) { return L("Через ") + Format.until(e.start.timeIntervalSinceNow) + " · " + start }
        return Format.when(e.start)
    }

    /// "18:30–19:00 · Google Meet".
    static func span(_ e: CalendarStore.Event) -> String {
        let time = e.allDay ? L("весь день")
            : "\(e.start.formatted(date: .omitted, time: .shortened))–\(e.end.formatted(date: .omitted, time: .shortened))"
        let place = e.meetingURL.map { Meeting.name($0) } ?? e.location
        return [time, place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
