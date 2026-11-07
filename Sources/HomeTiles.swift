import AppKit
import SwiftUI

// MARK: Home (Figma «H · Главная»: a 4 × 2 grid of quiet tiles; only what waits for you is warm)

struct HomeTab: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        GeometryReader { geo in
            let col = (geo.size.width - 3 * Spacing.gap) / 4
            let row = (geo.size.height - Spacing.gap) / 2
            HStack(alignment: .top, spacing: Spacing.gap) {
                VStack(spacing: Spacing.gap) {
                    MusicTile(np: model.nowPlaying).frame(height: row).entrance(0)
                    HStack(spacing: Spacing.gap) {
                        WeatherTile(weather: model.weather).frame(width: col).entrance(3)
                        LimitsTile(limits: model.limits) { model.showLimits = true; model.select(.ai) }.frame(width: col).entrance(4)
                    }
                    .frame(height: row)
                }
                .frame(width: 2 * col + Spacing.gap)
                VStack(spacing: Spacing.gap) {
                    EventTile(store: model.calendar) { model.select(.calendar) }.frame(height: row).entrance(1)
                    TimerTile(model: model, timer: model.timer) { model.select(.timer) }.frame(height: row).entrance(5)
                }
                .frame(width: col)
                AgentsTile(agents: model.agents) { model.select(.ai) }.frame(width: col).entrance(2)
            }
        }
    }
}

/// The playing track: cover, title, controls and a thin progress line; the cover's colour glows inside the tile.
struct MusicTile: View {
    @ObservedObject var np: NowPlaying

    var body: some View {
        let colors = np.glowColors
        Group {
            if np.hasTrack { playing } else { idle }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The cover's light from the lower left; a background never changes the tile's size.
        .background(alignment: .bottomLeading) {
            if np.hasTrack {
                Ellipse().fill(EllipticalGradient(colors: [colors[0].opacity(0.32), colors[1].opacity(0.1), .clear]))
                    .frame(width: 420, height: 200).offset(x: -150, y: 60)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
        .tile()
        .animation(Motion.smooth, value: np.hasTrack)
        .animation(Motion.reduce ? nil : .easeInOut(duration: 0.6).speed(Motion.speed), value: colors)
    }

    private var playing: some View {
        HStack(alignment: .top, spacing: 13) {
            Button { np.openPlayer() } label: {
                Artwork(image: np.artwork, size: 96, radius: 14).id(np.artwork)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .buttonStyle(.icon)
            .help("Открыть \(np.source?.name ?? "плеер")")
            VStack(alignment: .leading, spacing: 0) {
                TileHeader(symbol: "headphones", color: Tone.focus, title: np.isPlaying ? L("Музыка") : L("На паузе"))
                Text(np.title).font(.system(size: 17, weight: .bold)).tracking(-0.3).lineLimit(1)
                    .padding(.top, 6).contentTransition(.opacity)
                Text(np.artist).font(.system(size: 12.5)).foregroundStyle(muted).lineLimit(1).contentTransition(.opacity)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    control("backward.fill", np.previous)
                    Button(action: np.playPause) {
                        Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 26, height: 26).background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.icon)
                    control("forward.fill", np.next)
                    MiniProgress(np: np)
                }
                .frame(height: 26)
            }
        }
        .padding(Spacing.pad)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 0) {
            TileHeader(symbol: "headphones", color: Tone.focus, title: L("Музыка"))
            Text("Ничего не играет").font(.system(size: 15, weight: .semibold)).padding(.top, 8)
            Text("Музыка из любого приложения появится здесь").font(.system(size: 12)).foregroundStyle(muted).lineLimit(1)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Button("Spotify") { np.launch(.spotify) }.buttonStyle(.pill(.ghost, small: true))
                Button("Музыка") { np.launch(.music) }.buttonStyle(.pill(.ghost, small: true))
            }
        }
        .padding(Spacing.pad)
    }

    private func control(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).frame(width: 20, height: 26)
        }
        .buttonStyle(.icon)
    }
}

/// A thin playback line for the music tile; drag to seek.
private struct MiniProgress: View {
    @ObservedObject var np: NowPlaying
    @State private var drag: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fraction = drag ?? (np.duration > 0 ? np.livePosition(at: context.date) / np.duration : 0)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: geo.size.width * min(max(fraction, 0), 1))
                }
                .frame(height: 3)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag = min(max(0, $0.location.x / geo.size.width), 1) }
                    .onEnded { value in
                        np.seek(to: min(max(0, value.location.x / geo.size.width), 1) * np.duration)
                        drag = nil
                    })
            }
        }
    }
}

/// The next event: weekday and date, when it starts, the title, and the way in.
struct EventTile: View {
    @ObservedObject var store: CalendarStore
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            Tile {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        TileIcon(symbol: "calendar", color: Tone.deny)
                        Text(Date().formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(Color(hex: 0xFF8A80))
                        Spacer(minLength: 0)
                        Text(Date().formatted(.dateTime.day())).font(.rounded(22, .heavy))
                    }
                    content
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }

    @ViewBuilder private var content: some View {
        if let e = store.nextEvent {
            Text(Self.when(e)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Tone.meeting).lineLimit(1)
                .padding(.top, 10)
            Text(e.title).font(.system(size: 13.5, weight: .bold)).lineLimit(2).padding(.top, 3)
            Spacer(minLength: 0)
            if let url = e.meetingURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label(L("Войти в ") + Meeting.name(url), systemImage: "video.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Tone.done).lineLimit(1)
                }
                .buttonStyle(.icon)
            }
        } else if !store.calendarAccess {
            Text("Покажу встречи").font(.system(size: 13.5, weight: .bold)).padding(.top, 10)
            Spacer(minLength: 0)
            Button("Разрешить") { store.requestAccess() }.buttonStyle(.pill(.ghost, small: true))
        } else {
            Text("Сегодня свободно").font(.system(size: 13.5, weight: .bold)).padding(.top, 10)
            Spacer(minLength: 0)
            Text(store.reminders.isEmpty ? L("Напоминаний нет") : Format.count(store.reminders.count, "напоминание", "напоминания", "напоминаний"))
                .font(.system(size: 11)).foregroundStyle(muted)
        }
    }

    /// "18:30 · через 25 мин", "идёт · до 19:00".
    static func when(_ e: CalendarStore.Event) -> String {
        let start = e.start.formatted(date: .omitted, time: .shortened)
        if e.start <= Date() { return L("идёт · до ") + e.end.formatted(date: .omitted, time: .shortened) }
        if !Calendar.current.isDateInToday(e.start) { return Format.when(e.start) }
        return start + " · " + L("через ") + Format.until(e.start.timeIntervalSinceNow)
    }
}

/// Agents at a glance: how many wait for you (warm tile) or work, and every session in a short list.
struct AgentsTile: View {
    @ObservedObject var agents: AgentHub
    var open: () -> Void

    var body: some View {
        let waiting = agents.sessions.filter(\.needsYou).count
        let working = agents.sessions.filter { $0.status == .working }.count
        let sorted = agents.sessions.sorted { $0.rank < $1.rank || ($0.rank == $1.rank && $0.updated > $1.updated) }
        Button(action: open) {
            Tile(kind: waiting > 0 ? .attention : .plain) {
                VStack(alignment: .leading, spacing: 0) {
                    TileHeader(symbol: "sparkles", title: L("Агенты"))
                    if sorted.isEmpty {
                        Spacer(minLength: 0)
                        Text(agents.hooksInstalled ? L("Нет активных сессий") : L("Nook не подключён к агентам"))
                            .font(.system(size: 13, weight: .semibold))
                        Text(agents.hooksInstalled ? L("Claude Code и Codex появятся здесь") : L("Подключите во вкладке «Агенты»"))
                            .font(.system(size: 11)).foregroundStyle(muted).padding(.top, 2)
                        Spacer(minLength: 0)
                    } else {
                        Text("\(waiting > 0 ? waiting : working)").font(.rounded(54, .heavy)).tracking(-1.5)
                            .foregroundStyle(waiting > 0 ? Tone.attention : .white)
                            .contentTransition(.numericText())
                            .padding(.top, 10)
                        Text(waiting > 0 ? L("ждёт тебя") : (working > 0 ? L("в работе") : L("сессий открыто")))
                            .font(.system(size: 13.5, weight: .semibold))
                        VStack(alignment: .leading, spacing: Spacing.list) {
                            ForEach(sorted.prefix(waiting > 0 ? 3 : 4)) { s in row(s) }
                        }
                        .padding(.top, 12)
                        Spacer(minLength: 0)
                        if waiting > 0 {
                            Text("Ответить").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                                .frame(maxWidth: .infinity).frame(height: 30).background(Capsule().fill(Color.white))
                        }
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .help("Все сессии  ⌘4")
        .animation(Motion.smooth, value: agents.sessions.map(\.id))
        .animation(Motion.smooth, value: waiting)
    }

    private func row(_ s: AgentHub.Session) -> some View {
        HStack(spacing: 7) {
            Monogram(project: s.project, size: 15, lit: s.status == .working)
            Text(s.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 2)
            Group {
                switch s.status {
                case .done: Text("готово").foregroundStyle(Tone.done)
                case .waiting, .attention: Text("ждёт").foregroundStyle(Tone.attention)
                default: Text(s.shortTime).foregroundStyle(faint)
                }
            }
            .font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
    }
}

extension AgentHub.Session {
    /// "2 мин": how long the turn has gone on, or since the last event.
    var shortTime: String {
        if status == .working, let start = turnStarted { return Format.span(Date().timeIntervalSince(start)) }
        return Format.span(Date().timeIntervalSince(updated))
    }
}

/// The place, the temperature in large numbers, and the day's range.
struct WeatherTile: View {
    @ObservedObject var weather: Weather

    var body: some View {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app")) } label: {
            Tile {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Text(weather.place.isEmpty ? L("Погода") : weather.place)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 16))
                    }
                    Text(weather.temperature.map { "\(Int($0.rounded()))°" } ?? "—").font(.rounded(38, .heavy))
                        .contentTransition(.numericText()).padding(.top, 6)
                    Spacer(minLength: 0)
                    Text([weather.summary, weather.high.flatMap { h in weather.low.map { "↑\(Int(h.rounded()))° ↓\(Int($0.rounded()))°" } }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.85)
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .help("Открыть Погоду")
    }
}

/// What is left of each agent limit, one row per window, in the same colours as the line under the feed.
struct LimitsTile: View {
    @ObservedObject var limits: Limits
    var open: () -> Void

    var body: some View {
        let windows = limits.windows
        Button(action: open) {
            Tile {
                VStack(alignment: .leading, spacing: 0) {
                    TileHeader(symbol: "gauge.with.dots.needle.50percent", color: Tone.limit, title: L("Лимиты"))
                    if windows.isEmpty {
                        Spacer(minLength: 0)
                        Text("Появятся, когда агент начнёт работу").font(.system(size: 11)).foregroundStyle(muted)
                    } else {
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: Spacing.list) {
                            ForEach(windows.prefix(3)) { w in
                                HStack(spacing: 6) {
                                    Text(w.provider.glyph).font(.system(size: 11)).foregroundStyle(Tone.ink).frame(width: 12)
                                    Text(w.label).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
                                        .frame(width: 30, alignment: .leading)
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.white.opacity(0.1))
                                            Capsule().fill(w.color).frame(width: geo.size.width * CGFloat(w.left) / 100)
                                        }
                                    }
                                    .frame(height: 4)
                                    Text("\(w.left)%").font(.rounded(12, .heavy))
                                        .foregroundStyle(w.state == .ok ? Color.white : w.color)
                                        .frame(width: 36, alignment: .trailing)
                                }
                                .frame(height: 16)
                                .help(L("\(w.provider.title) · \(w.title): осталось \(w.left)%"))
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .help("Лимиты агентов  ⌘4")
    }
}

/// The running timer in large numbers with its phase, or a quick way to start one.
struct TimerTile: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var timer: FocusTimer
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            Tile {
                VStack(alignment: .leading, spacing: 0) {
                    TileHeader(symbol: "timer", color: Tone.focus, title: timer.phase.title)
                    if timer.isRunning || timer.isPaused {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = timer.remaining(at: context.date)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(FocusTimer.format(remaining)).font(.rounded(30, .heavy)).monospacedDigit()
                                    .contentTransition(.numericText(countsDown: true)).padding(.top, 8)
                                Spacer(minLength: 0)
                                HStack(spacing: 8) {
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.white.opacity(0.12))
                                            Capsule().fill(timer.phase.toneColor).frame(width: geo.size.width * timer.progress)
                                        }
                                    }
                                    .frame(width: 40, height: 4)
                                    Text(timer.isPaused ? L("на паузе") : (timer.pomodoro ? L("помодоро \(timer.completedFocus % 4 + 1) из 4") : L("до ") + Date().addingTimeInterval(remaining).formatted(date: .omitted, time: .shortened)))
                                        .font(.system(size: 10.5)).foregroundStyle(muted).lineLimit(1)
                                }
                            }
                        }
                    } else {
                        Text("Не идёт").font(.system(size: 15, weight: .semibold)).padding(.top, 8)
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            Button("25 мин") { timer.pomodoro = false; timer.start(minutes: 25) }.buttonStyle(.pill(.ghost, small: true))
                            Button("Помодоро") { model.endFocusMode(); timer.startPomodoro() }.buttonStyle(.pill(.ghost, small: true))
                        }
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }
}
