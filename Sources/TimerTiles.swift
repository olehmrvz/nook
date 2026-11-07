import AppKit
import SwiftUI

// MARK: Timer (Figma «Таймер · H × шкала из G»: the ring, the pomodoro strip with the calendar, quick start)

struct TimerTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var timer: FocusTimer
    @ObservedObject var calendar: CalendarStore

    private let presets: [Double] = [1, 3, 5, 10, 15, 25, 45, 60]

    var body: some View {
        GeometryReader { geo in
            let col = (geo.size.width - 3 * Spacing.gap) / 4
            let row = (geo.size.height - Spacing.gap) / 2
            HStack(alignment: .top, spacing: Spacing.gap) {
                ring.frame(width: col).entrance(0)
                VStack(spacing: Spacing.gap) {
                    PomodoroStrip(model: model, timer: timer, calendar: calendar).frame(height: row).entrance(1)
                    HStack(spacing: Spacing.gap) {
                        quickStart.frame(width: 2 * col + Spacing.gap).entrance(2)
                        addTile.frame(width: col).entrance(3)
                    }
                    .frame(height: row)
                }
            }
        }
        .animation(Motion.smooth, value: timer.isRunning || timer.isPaused)
    }

    private var active: Bool { timer.isRunning || timer.isPaused }

    private var ring: some View {
        Tile {
            VStack(spacing: 0) {
                HStack {
                    TileHeader(symbol: "timer", color: Tone.focus,
                               title: timer.phase == .focus ? L("Фокус \(timer.completedFocus % 4 + 1)") : timer.phase.title)
                }
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let remaining = timer.remaining(at: context.date)
                    let fraction = timer.total > 0 ? remaining / timer.total : 0
                    ZStack {
                        RingGauge(fraction: active ? fraction : 1, colors: [timer.phase.toneColor, timer.phase.toneColor], lineWidth: 9)
                        VStack(spacing: 4) {
                            Text(FocusTimer.format(remaining)).font(.rounded(30, .heavy)).monospacedDigit()
                                .contentTransition(.numericText(countsDown: true))
                                .animation(Motion.quick, value: Int(remaining))
                            Text(active ? L("из ") + FocusTimer.format(timer.total) : L("не идёт"))
                                .font(.system(size: 11)).foregroundStyle(muted)
                        }
                    }
                    .frame(width: 138, height: 138)
                }
                .padding(.top, 14)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if active {
                        Button(timer.isPaused ? L("Дальше") : L("Пауза")) { timer.pauseResume() }.buttonStyle(.pill(.primary, small: true))
                        Button(model.focusMode ? L("Стоп") : L("Сброс")) { timer.reset() }.buttonStyle(.pill(.ghost, small: true))
                    } else {
                        Button("Помодоро") { model.endFocusMode(); timer.startPomodoro() }.buttonStyle(.pill(.primary, small: true))
                            .help("25 минут работы, 5 минут отдыха")
                        Button { model.startFocusMode() } label: { Image(systemName: "moon.fill") }
                            .buttonStyle(.pill(.ghost, small: true))
                            .help("Режим фокуса: помодоро, кофеин и тишина — пока идёт фокус, Nook не показывает уведомления приложений (звонки показывает). «Стоп» выключает режим")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var quickStart: some View {
        Tile {
            VStack(alignment: .leading, spacing: 8) {
                Caps(text: L("Быстрый старт"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                    ForEach(presets, id: \.self) { m in
                        Button(m >= 60 ? L("1 ч") : L("\(Int(m)) м")) { timer.pomodoro = false; timer.start(minutes: m) }
                            .buttonStyle(PresetStyle())
                    }
                }
            }
        }
    }

    private var addTile: some View {
        Tile {
            VStack(alignment: .leading, spacing: 0) {
                TileHeader(symbol: "plus", title: L("Добавить"))
                HStack(spacing: 6) {
                    Button("+1 мин") { timer.add(minutes: 1) }.buttonStyle(.pill(.ghost, small: true))
                    Button("+5 мин") { timer.add(minutes: 5) }.buttonStyle(.pill(.ghost, small: true))
                }
                .disabled(!active)
                .opacity(active ? 1 : 0.5)
                .padding(.top, 12)
                Spacer(minLength: 0)
                Text(nextWords).font(.system(size: 10.5)).foregroundStyle(muted).lineSpacing(1.5).lineLimit(2)
            }
        }
    }

    /// What happens when this block ends: "Перерыв 5 мин в 18:20, потом фокус 3".
    private var nextWords: String {
        guard active else { return L("Запустите таймер или помодоро") }
        let end = Date().addingTimeInterval(timer.remaining()).formatted(date: .omitted, time: .shortened)
        guard timer.pomodoro else { return L("Закончится в \(end)") }
        switch timer.phase {
        case .focus:
            let long = (timer.completedFocus + 1) % 4 == 0
            return long ? L("Длинный перерыв 15 мин в \(end)") : L("Перерыв 5 мин в \(end), потом фокус \(timer.completedFocus % 4 + 2)")
        default:
            return L("Фокус \(timer.completedFocus % 4 + 1) в \(end)")
        }
    }
}

extension FocusTimer.Phase {
    /// The redesign's colour of a phase: focus pink, breaks green.
    var toneColor: Color {
        switch self {
        case .focus, .plain: return Tone.focus
        case .shortBreak, .longBreak: return Tone.done
        }
    }
}

/// Grey preset buttons of the quick start grid.
struct PresetStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { PresetBody(configuration: configuration) }
}

private struct PresetBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.12 : 0.07)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

// MARK: Pomodoro strip

/// The set of four focus blocks on a time line, with the calendar's meetings on their own lane, so a clash
/// is visible before it happens. Not running: how a pomodoro started now would lie.
struct PomodoroPlan {
    struct Block: Identifiable {
        let id: Int
        let start: Date
        let end: Date
        let phase: FocusTimer.Phase
        /// Focus number in the set, 1…4; 0 for breaks.
        let number: Int
        let past: Bool
        let current: Bool
    }
    let blocks: [Block]
    let preview: Bool

    private static let set: [(FocusTimer.Phase, TimeInterval)] = [(.focus, 25), (.shortBreak, 5), (.focus, 25), (.shortBreak, 5),
                                                                  (.focus, 25), (.shortBreak, 5), (.focus, 25), (.longBreak, 15)]

    static func make(_ timer: FocusTimer, now: Date) -> PomodoroPlan {
        let active = timer.isRunning || timer.isPaused
        let remaining = timer.remaining(at: now)
        if active && !timer.pomodoro {
            return PomodoroPlan(blocks: [Block(id: 0, start: now.addingTimeInterval(remaining - timer.total), end: now.addingTimeInterval(remaining),
                                               phase: .plain, number: 0, past: false, current: true)], preview: false)
        }
        let n = timer.completedFocus
        let pos: Int
        switch (active, timer.phase) {
        case (false, _): pos = 0
        case (_, .focus): pos = 2 * (n % 4)
        case (_, .longBreak): pos = 7
        default: pos = 2 * ((n - 1 + 4) % 4) + 1
        }
        let curStart = active ? now.addingTimeInterval(remaining - timer.total) : now
        let curEnd = active ? now.addingTimeInterval(remaining) : now.addingTimeInterval(25 * 60)
        var blocks: [Block] = []
        var t = curStart
        for j in stride(from: pos - 1, through: 0, by: -1) {
            let start = t.addingTimeInterval(-set[j].1 * 60)
            blocks.insert(Block(id: j, start: start, end: t, phase: set[j].0, number: j % 2 == 0 ? j / 2 + 1 : 0, past: true, current: false), at: 0)
            t = start
        }
        blocks.append(Block(id: pos, start: curStart, end: curEnd, phase: set[pos].0, number: pos % 2 == 0 ? pos / 2 + 1 : 0,
                            past: false, current: active))
        t = curEnd
        for j in (pos + 1)..<set.count {
            let end = t.addingTimeInterval(set[j].1 * 60)
            blocks.append(Block(id: j, start: t, end: end, phase: set[j].0, number: j % 2 == 0 ? j / 2 + 1 : 0, past: false, current: false))
            t = end
        }
        return PomodoroPlan(blocks: blocks, preview: !active)
    }
}

struct PomodoroStrip: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var timer: FocusTimer
    @ObservedObject var calendar: CalendarStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let now = context.date
            let plan = PomodoroPlan.make(timer, now: now)
            Tile {
                VStack(alignment: .leading, spacing: 8) {
                    title(plan)
                    lanes(plan, now: now)
                }
            }
        }
    }

    private func title(_ plan: PomodoroPlan) -> some View {
        let done = plan.blocks.filter { $0.phase == .focus && $0.past }.count
        let end = plan.blocks.last?.end.formatted(date: .omitted, time: .shortened) ?? ""
        return HStack(spacing: 8) {
            TileIcon(symbol: "flame.fill", color: Tone.focus, size: 18)
            Text(timer.pomodoro || plan.preview ? L("Помодоро 25 / 5") : L("Таймер"))
                .font(.system(size: 12.5, weight: .bold)).lineLimit(1).fixedSize()
            if timer.pomodoro || plan.preview {
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(i < done ? Tone.focus : Color.white.opacity(0.18)).frame(width: 7, height: 7)
                    }
                }
                Text(plan.preview ? L("если начать сейчас · до \(end)") : L("\(done) из 4 · до \(end)"))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.focusMode {
                Label(model.focusQuiet ? L("уведомления ждут") : L("перерыв: уведомления видны"),
                      systemImage: model.focusQuiet ? "moon.fill" : "cup.and.saucer.fill")
                    .font(.system(size: 10.5)).foregroundStyle(muted).lineLimit(1)
            }
        }
        .frame(height: 20)
    }

    private func lanes(_ plan: PomodoroPlan, now: Date) -> some View {
        GeometryReader { geo in
            let t0 = (plan.blocks.first?.start ?? now).addingTimeInterval(-5 * 60)
            let t1 = (plan.blocks.last?.end ?? now).addingTimeInterval(5 * 60)
            let span = max(t1.timeIntervalSince(t0), 60)
            let x = { (d: Date) in CGFloat(d.timeIntervalSince(t0) / span) * geo.size.width }
            let meetings = calendar.events.filter { !$0.allDay && $0.end > t0 && $0.start < t1 }
            let clash = meetings.lazy.compactMap { m in
                plan.blocks.first { $0.phase == .focus && !$0.past && $0.start < m.end && $0.end > m.start }.map { (m, $0) }
            }.first
            ZStack(alignment: .topLeading) {
                // Half-hour ticks.
                ForEach(Self.ticks(t0, t1), id: \.self) { tick in
                    Text(tick.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.38))
                        .fixedSize()
                        .position(x: x(tick), y: 6)
                }
                // Focus and breaks.
                ForEach(plan.blocks) { b in
                    block(b, now: now, width: max(2, x(b.end) - x(b.start) - 2)).offset(x: x(b.start) + 1, y: 18)
                }
                // Meetings on their own lane; a clash with a focus block is said in yellow.
                ForEach(meetings) { m in
                    let w = max(24, x(m.end) - x(m.start) - 2)
                    Text(m.title).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Color(hex: 0xD9D1FF)).lineLimit(1)
                        .padding(.horizontal, 7)
                        .frame(width: w, height: 20, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Tone.meeting.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Tone.meeting.opacity(0.7))))
                        .offset(x: x(m.start) + 1, y: 48)
                        .help("\(m.title) · \(CalendarTab.span(m))")
                }
                if let (m, b) = clash {
                    let after = x(m.end) + 8
                    HStack(spacing: 5) {
                        Circle().fill(Tone.attention).frame(width: 6, height: 6)
                        Text(L("попадает на фокус \(b.number)")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Tone.attention)
                    }
                    .fixedSize()
                    .offset(x: after + 110 < geo.size.width ? after : max(0, x(m.start) - 120), y: 51)
                }
                // Now.
                if now >= t0 && now <= t1 {
                    RoundedRectangle(cornerRadius: 1).fill(Tone.now).frame(width: 2, height: 56).offset(x: x(now) - 1, y: 12)
                    Text(now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(Color(hex: 0x0D1400))
                        .padding(.horizontal, 6).frame(height: 15)
                        .background(Capsule().fill(Tone.now))
                        .fixedSize()
                        .position(x: min(max(x(now), 22), geo.size.width - 22), y: 6)
                }
            }
        }
    }

    @ViewBuilder private func block(_ b: PomodoroPlan.Block, now: Date, width: CGFloat) -> some View {
        let focus = b.phase == .focus || b.phase == .plain
        let color = focus ? Tone.focus : Tone.done
        let label: String = {
            switch b.phase {
            case .focus: return b.past ? L("Фокус \(b.number) ✓") : L("Фокус \(b.number)")
            case .longBreak: return L("Отдых 15")
            case .plain: return L("Таймер")
            case .shortBreak: return ""
            }
        }()
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.opacity(b.past ? 0.22 : (focus ? 0.42 : 0.32)))
            if b.current {
                // The part already behind you, brighter.
                let done = min(max(now.timeIntervalSince(b.start) / max(b.end.timeIntervalSince(b.start), 1), 0), 1)
                UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7, style: .continuous)
                    .fill(color.opacity(0.6)).frame(width: width * done)
            }
            if width > 50 && !label.isEmpty {
                Text(b.phase == .longBreak && width < 76 ? L("Отдых") : label).font(.system(size: 10.5, weight: .bold)).foregroundStyle(focus ? Color(hex: 0xFFE0EE) : Color(hex: 0xCFF5D9))
                    .lineLimit(1).padding(.leading, 7)
            }
        }
        .frame(width: width, height: 24)
        .opacity(b.past ? 0.65 : 1)
    }

    /// Every half hour inside the window.
    private static func ticks(_ t0: Date, _ t1: Date) -> [Date] {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: t0)
        c.minute = (c.minute ?? 0) < 30 ? 30 : 0
        if c.minute == 0 { c.hour = (c.hour ?? 0) + 1 }
        guard var t = cal.date(from: c) else { return [] }
        var out: [Date] = []
        while t < t1.addingTimeInterval(-6 * 60) {
            if t.timeIntervalSince(t0) > 6 * 60 { out.append(t) }
            t = t.addingTimeInterval(30 * 60)
        }
        return out
    }
}
