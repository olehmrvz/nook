import AppKit
import SwiftUI

// MARK: Root

/// `defaults write dev.nook.app slowMotion -float 8` slows every notch animation down for inspection.
enum Motion {
    static let speed: Double = {
        let factor = UserDefaults.standard.double(forKey: "slowMotion")
        return factor > 1 ? 1 / factor : 1
    }()
}

struct RootView: View {
    @ObservedObject var model: NotchModel

    private enum Mode: Equatable { case collapsed, island, prompter, expanded }

    private var mode: Mode {
        if model.expanded { return .expanded }
        if model.cuely.isPresenting { return .prompter }
        if model.island != nil { return .island }
        return .collapsed
    }

    private var size: CGSize {
        switch mode {
        case .expanded:
            return CGSize(width: NotchModel.expandedSize.width + 2 * NotchModel.ear, height: NotchModel.expandedSize.height)
        case .prompter: return NotchModel.prompterSize
        case .island: return CGSize(width: NotchModel.islandWidth, height: model.notch.height + NotchModel.islandExtra)
        case .collapsed: return CGSize(width: model.collapsedWidth, height: model.notch.height)
        }
    }

    private var radius: CGFloat { mode == .collapsed ? 11 : (mode == .expanded ? 26 : 22) }

    /// Opening bounces a little; closing settles without overshoot so the notch never dips under the camera.
    private var spring: Animation {
        (mode == .collapsed ? Animation.spring(response: 0.34, dampingFraction: 1.0) : .spring(response: 0.42, dampingFraction: 0.82))
            .speed(Motion.speed)
    }

    /// Content fades in after the shape has started to grow and fades out before it shrinks.
    private static let contentTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
            .animation(.easeOut(duration: 0.22).delay(0.08).speed(Motion.speed)),
        removal: .opacity.animation(.easeIn(duration: 0.09).speed(Motion.speed)))

    var body: some View {
        VStack(spacing: 0) {
            // The container persists across modes, so its frame and clip animate together with the
            // black shape; newly inserted content can never draw outside it, also mid-animation.
            ZStack(alignment: .top) { content }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(NotchShape(bottomRadius: radius))
                .background(alignment: .top) {
                    NotchShape(bottomRadius: radius)
                        .fill(Color.black)
                        .shadow(color: .black.opacity(mode == .collapsed ? 0 : 0.45), radius: 18, y: 8)
                }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                model.dropFiles(providers)
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(spring, value: mode)
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: model.hasLiveActivity)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .expanded:
            ExpandedView(model: model)
                .padding(.horizontal, NotchModel.ear + 18)
                .padding(.top, 6)
                .padding(.bottom, 16)
                .frame(width: NotchModel.expandedSize.width + 2 * NotchModel.ear, height: NotchModel.expandedSize.height)
                .transition(Self.contentTransition)
        case .prompter:
            PrompterView(cuely: model.cuely, notch: model.notch)
                .padding(.horizontal, NotchModel.ear + 14)
                .frame(width: NotchModel.prompterSize.width, height: NotchModel.prompterSize.height)
                .transition(Self.contentTransition)
        case .island:
            if let island = model.island {
                IslandView(model: model, island: island)
                    .padding(.horizontal, NotchModel.ear + 14)
                    .padding(.top, model.notch.height + 4)
                    .padding(.bottom, 12)
                    .frame(width: NotchModel.islandWidth, height: model.notch.height + NotchModel.islandExtra)
                    .transition(Self.contentTransition)
            }
        case .collapsed:
            CollapsedView(model: model)
                .padding(.horizontal, NotchModel.ear)
                .transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.12).speed(Motion.speed)))
        }
    }
}

// MARK: Collapsed

struct CollapsedView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 0) {
            leftSlot.frame(width: model.hasLiveActivity ? NotchModel.slot : 0)
            Spacer(minLength: model.notch.width)
            rightSlot.frame(width: model.hasLiveActivity ? NotchModel.slot : 0)
        }
        .frame(height: model.notch.height)
        .clipped()
    }

    @ViewBuilder private var leftSlot: some View {
        switch model.flash {
        case .charging:
            Image(systemName: "bolt.fill").foregroundStyle(.green)
        case .screenshot(let url):
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 24, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        case .copied:
            Image(systemName: "doc.on.clipboard.fill")
        case nil:
            switch model.live {
            case .permission: Image(systemName: "sparkles").foregroundStyle(accent)
            case .timer: Image(systemName: "timer").foregroundStyle(timerColor)
            case .download: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            case .agents: Image(systemName: "sparkles").foregroundStyle(muted)
            case .music: Artwork(image: model.nowPlaying.artwork, size: 22, radius: 5)
            case .prompter, nil: EmptyView()
            }
        }
    }

    @ViewBuilder private var rightSlot: some View {
        switch model.flash {
        case .charging(let percent):
            Text("\(percent)%").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
        case .screenshot:
            Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(muted)
        case .copied:
            Image(systemName: "checkmark").foregroundStyle(.green)
        case nil:
            switch model.live {
            case .permission: PulseDot(color: accent)
            case .timer:
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text(FocusTimer.format(model.timer.remaining(at: context.date)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(model.timer.isPaused ? muted : timerColor)
                }
            case .download: DownloadRing(fraction: model.downloads.active?.fraction)
            case .agents: Spinner()
            case .music: Bars()
            case .prompter, nil: EmptyView()
            }
        }
    }

    private var timerColor: Color {
        switch model.timer.phase {
        case .shortBreak, .longBreak: return .green
        case .focus: return Color(red: 1, green: 0.42, blue: 0.35)
        case .plain: return accent
        }
    }
}

struct DownloadRing: View {
    var fraction: Double?
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
            if let fraction {
                Circle().trim(from: 0, to: fraction).stroke(Color.blue, style: .init(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Spinner().scaleEffect(0.55)
            }
        }
        .frame(width: 16, height: 16)
        .animation(.linear(duration: 0.3), value: fraction)
    }
}

// MARK: Islands

struct IslandView: View {
    @ObservedObject var model: NotchModel
    let island: Island
    @State private var callImage: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            leading.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) { text }
            Spacer(minLength: 4)
            trailing
            Button { model.dismissIsland() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(muted)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { primaryAction() }
        .contextMenu { menu }
        .onAppear {
            if case .call(let name, _) = island.kind {
                NotificationWatcher.contactImage(named: name) { callImage = $0 }
            }
        }
    }

    @ViewBuilder private var leading: some View {
        switch island.kind {
        case .agentDone(let provider, _, _, _, _):
            ZStack {
                Circle().fill(provider == "codex" ? Color.white.opacity(0.15) : Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.25))
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.green)
            }
        case .notification(let bundleID, _, _, _):
            if let icon = NotificationWatcher.icon(for: bundleID) { Image(nsImage: icon).resizable() }
            else { Image(systemName: "bell.fill") }
        case .call:
            if let callImage {
                Image(nsImage: callImage).resizable().scaledToFill().clipShape(Circle())
            } else {
                ZStack { Circle().fill(Color.green.opacity(0.25)); Image(systemName: "phone.fill").foregroundStyle(.green) }
            }
        case .airpods(let name, _):
            Image(systemName: name.lowercased().contains("max") ? "airpodsmax" : (name.lowercased().contains("airpods") ? "airpodspro" : "headphones"))
                .font(.system(size: 26))
        case .download:
            ZStack { Circle().fill(Color.blue.opacity(0.25)); Image(systemName: "arrow.down").font(.system(size: 16, weight: .bold)).foregroundStyle(.blue) }
        case .timerDone:
            ZStack { Circle().fill(accent.opacity(0.25)); Image(systemName: "timer").font(.system(size: 17, weight: .semibold)).foregroundStyle(accent) }
        case .event:
            ZStack { Circle().fill(Color.red.opacity(0.22)); Image(systemName: "calendar").font(.system(size: 16, weight: .semibold)).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var text: some View {
        switch island.kind {
        case .agentDone(let provider, let project, let message, let duration, _):
            Text("\(provider == "codex" ? "Codex" : "Claude") · \(project) — готово")
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if let duration { Text("Задача заняла \(Self.span(duration))").font(.system(size: 10)).foregroundStyle(muted) }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(2) }
        case .notification(_, let app, let title, let body):
            Text(app).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if !body.isEmpty { Text(body).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).lineLimit(2) }
        case .call(let name, let bundleID):
            Text(name.isEmpty ? "Входящий звонок" : name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text("Звонок · \(NotificationWatcher.appName(for: bundleID))").font(.system(size: 11)).foregroundStyle(muted)
        case .airpods(let name, let levels):
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if levels.isEmpty {
                Text("Подключены").font(.system(size: 11)).foregroundStyle(muted)
            } else {
                HStack(spacing: 8) {
                    ForEach(levels.sorted(by: { $0.key < $1.key }), id: \.key) { label, value in
                        HStack(spacing: 3) {
                            Text(label).foregroundStyle(muted)
                            Text("\(value)%").foregroundStyle(value <= 20 ? .red : .green)
                        }
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                    }
                }
            }
        case .download(let name, _):
            Text("Загружено").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        case .timerDone(let title, let subtitle):
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(muted)
        case .event(let title, let start, _):
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text("Начало в \(start.formatted(date: .omitted, time: .shortened)) · \(start.formatted(.relative(presentation: .named)))")
                .font(.system(size: 11)).foregroundStyle(muted)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch island.kind {
        case .download(_, let path):
            HStack(spacing: 6) {
                pill("Открыть") { NSWorkspace.shared.open(URL(fileURLWithPath: path)); model.dismissIsland() }
                pill("На полку") { model.shelf.add([URL(fileURLWithPath: path)]); model.dismissIsland() }
            }
        case .timerDone:
            HStack(spacing: 6) {
                pill("+5 мин") { model.timer.start(minutes: 5); model.dismissIsland() }
                if model.timer.pomodoro { pill("Стоп") { model.timer.reset(); model.dismissIsland() } }
            }
        case .event(_, _, let url):
            if let url { pill("Подключиться", filled: true) { NSWorkspace.shared.open(url); model.dismissIsland() } }
        case .call(_, let bundleID):
            pill("Открыть", filled: true) { NotificationWatcher.open(bundleID: bundleID); model.dismissIsland() }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var menu: some View {
        if case .notification(let bundleID, let app, _, _) = island.kind {
            Button("Не показывать от «\(app)»") {
                var muted = Settings.mutedApps
                muted.insert(bundleID)
                Settings.mutedApps = muted
                model.dismissIsland()
            }
        }
        Button("Скрыть") { model.dismissIsland() }
    }

    private func primaryAction() {
        switch island.kind {
        case .agentDone(_, _, _, _, let pid): NotchModel.activateApp(owning: pid)
        case .notification(let bundleID, _, _, _), .call(_, let bundleID): NotificationWatcher.open(bundleID: bundleID)
        case .download(_, let path): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .event: model.calendar.openCalendar()
        case .airpods, .timerDone: break
        }
        model.dismissIsland()
    }

    private func pill(_ title: String, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(filled ? Color.green : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    static func span(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин" }
        return "\(s / 3600) ч \(s / 60 % 60) мин"
    }
}

// MARK: Prompter

struct PrompterView: View {
    @ObservedObject var cuely: Cuely
    let notch: CGSize
    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Color.clear.frame(height: notch.height - 6)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .center, spacing: 6) {
                        Color.clear.frame(height: 30)
                        ForEach(cuely.lines) { line in
                            Text(line.text)
                                .font(.system(size: cuely.fontSize, weight: .semibold))
                                .foregroundStyle(.white.opacity(line.id == cuely.currentLine ? 1 : (line.id < cuely.currentLine ? 0.28 : 0.55)))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .id(line.id)
                        }
                        Color.clear.frame(height: 120)
                    }
                }
                .onChange(of: cuely.currentLine) { _, line in
                    withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(line, anchor: UnitPoint(x: 0.5, y: 0.25)) }
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.15),
                                             .init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
            HStack(spacing: 14) {
                small(cuely.isPaused ? "play.fill" : "pause.fill") { cuely.togglePause() }
                if !cuely.voiceFollow {
                    small("tortoise.fill") { cuely.changeSpeed(-10) }
                    Text("\(Int(cuely.wordsPerMinute)) сл/мин").font(.system(size: 10).monospacedDigit()).foregroundStyle(muted)
                    small("hare.fill") { cuely.changeSpeed(10) }
                } else {
                    Label(cuely.status ?? "Голос", systemImage: "waveform").font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                }
                small("backward.end.fill") { cuely.restart() }
                small("xmark") { cuely.stop() }
            }
            .opacity(hover || cuely.isPaused ? 1 : 0.25)
            .padding(.bottom, 8)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onHover { hover = $0 }
        .onKeyPress(.space) { cuely.togglePause(); return .handled }
        .onKeyPress(.escape) { cuely.stop(); return .handled }
        .onKeyPress(.upArrow) { cuely.nudge(lines: -1); return .handled }
        .onKeyPress(.downArrow) { cuely.nudge(lines: 1); return .handled }
        .onKeyPress(.leftArrow) { cuely.changeSpeed(-10); return .handled }
        .onKeyPress(.rightArrow) { cuely.changeSpeed(10); return .handled }
    }

    private func small(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 11)).frame(width: 20, height: 18).contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }
}

// MARK: Expanded

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var agents: AgentHub
    @ObservedObject var battery: Battery
    @ObservedObject var weather: Weather

    init(model: NotchModel) {
        self.model = model
        agents = model.agents
        battery = model.battery
        weather = model.weather
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            Group {
                switch model.tab {
                case .home: HomeTab(model: model)
                case .clipboard: ClipboardTab(model: model, store: model.clipboard)
                case .shelf: ShelfTab(shelf: model.shelf)
                case .ai: AgentsTab(agents: model.agents, limits: model.limits)
                case .calendar: CalendarTab(store: model.calendar)
                case .timer: TimerTab(timer: model.timer)
                case .cuely: CuelyTab(model: model, cuely: model.cuely)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(Tab.leftSide) { tabButton($0) }
            Spacer(minLength: model.notch.width + 8)
            ForEach(Tab.rightSide) { tabButton($0) }
            if let t = weather.temperature {
                HStack(spacing: 3) {
                    Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 11))
                    Text("\(Int(t.rounded()))°").font(.system(size: 11, weight: .medium))
                }
                .padding(.leading, 6)
                .help("\(weather.place): \(weather.summary)")
            }
            if battery.hasBattery {
                Image(systemName: batteryIcon)
                    .foregroundStyle(battery.pluggedIn ? .green : (battery.percent <= 20 ? .red : .white.opacity(0.8)))
                    .padding(.leading, 6)
                    .help("\(battery.percent)%")
            }
        }
        .frame(height: max(model.notch.height - 6, 24))
    }

    private func tabButton(_ tab: Tab) -> some View {
        Button { model.tab = tab } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.icon).font(.system(size: 11))
                if model.tab == tab { Text(tab.title).font(.system(size: 12, weight: .semibold)).lineLimit(1) }
                if tab == .ai && !agents.permissions.isEmpty { Circle().fill(accent).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(model.tab == tab ? Color.white.opacity(0.14) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.tab == tab ? .white : muted)
        .help(tab.title)
    }

    private var batteryIcon: String {
        if battery.charging || battery.pluggedIn { return "battery.100percent.bolt" }
        switch battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

// MARK: Home

struct HomeTab: View {
    @ObservedObject var model: NotchModel
    var body: some View {
        HStack(spacing: 10) {
            NowPlayingCard(np: model.nowPlaying).frame(width: 300)
            VStack(spacing: 10) {
                NextEventCard(store: model.calendar) { model.tab = .calendar }
                WeatherCard(weather: model.weather, battery: model.battery)
            }
            .frame(width: 200)
            VStack(spacing: 10) {
                AgentsSummary(agents: model.agents) { model.tab = .ai }
                ShelfSummary(shelf: model.shelf, clipboard: model.clipboard) { model.tab = $0 }
            }
        }
    }
}

struct NextEventCard: View {
    @ObservedObject var store: CalendarStore
    var open: () -> Void
    var body: some View {
        Button(action: open) {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Дальше", systemImage: "calendar").font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                    if let e = store.nextEvent {
                        Text(e.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(e.start <= Date() ? "Идёт сейчас" : e.start.formatted(.relative(presentation: .named)))
                            .font(.system(size: 11)).foregroundStyle(Color(nsColor: e.color))
                    } else if !store.calendarAccess {
                        Text("Нет доступа к Календарю").font(.system(size: 12, weight: .medium))
                        Text("Откройте вкладку, чтобы разрешить").font(.system(size: 10)).foregroundStyle(muted)
                    } else {
                        Text("Событий больше нет").font(.system(size: 12, weight: .medium))
                        Text("\(store.reminders.count) напоминаний").font(.system(size: 10)).foregroundStyle(muted)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct WeatherCard: View {
    @ObservedObject var weather: Weather
    @ObservedObject var battery: Battery
    var body: some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(weather.place.isEmpty ? "Погода" : weather.place).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
                    Text(weather.temperature.map { "\(Int($0.rounded()))°" } ?? "—").font(.system(size: 26, weight: .medium))
                    if let h = weather.high, let l = weather.low {
                        Text("\(weather.summary) · \(Int(h.rounded()))° / \(Int(l.rounded()))°")
                            .font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 24))
            }
        }
    }
}

// MARK: Calendar

struct CalendarTab: View {
    @ObservedObject var store: CalendarStore
    @State private var newReminder = ""

    var body: some View {
        if !store.calendarAccess && !store.remindersAccess {
            Card {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.plus").font(.system(size: 26)).foregroundStyle(muted)
                    Text("Покажу события и напоминания прямо в вырезе").font(.system(size: 13, weight: .medium))
                    Button(store.asked ? "Открыть настройки доступа" : "Разрешить доступ") { store.requestAccess() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6).background(Capsule().fill(Color.white)).foregroundStyle(.black)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Card { events }.frame(maxWidth: .infinity)
                Card { reminders }.frame(width: 280)
            }
        }
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("События").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { store.openCalendar() } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(muted)
            }
            if store.events.isEmpty {
                Text("Сегодня и завтра свободно").font(.system(size: 11)).foregroundStyle(muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.events) { e in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.color)).frame(width: 3, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(Self.when(e)).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                            }
                            Spacer()
                            if let url = e.meetingURL {
                                Button("Подключиться") { NSWorkspace.shared.open(url) }
                                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.green.opacity(0.8)))
                            }
                        }
                    }
                }
            }
        }
    }

    private var reminders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Напоминания").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(muted)
                TextField("Новое напоминание", text: $newReminder)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .onSubmit { store.addReminder(newReminder); newReminder = "" }
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.reminders) { r in
                        HStack(spacing: 7) {
                            Button { store.complete(r) } label: {
                                Image(systemName: "circle").font(.system(size: 13)).foregroundStyle(Color(nsColor: r.color))
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(r.title).font(.system(size: 11)).lineLimit(1)
                                if let due = r.due {
                                    Text(due.formatted(.relative(presentation: .named)))
                                        .font(.system(size: 9)).foregroundStyle(due < Date() ? .red : muted)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func when(_ e: CalendarStore.Event) -> String {
        let day = Calendar.current.isDateInToday(e.start) ? "Сегодня" : (Calendar.current.isDateInTomorrow(e.start) ? "Завтра" : e.start.formatted(date: .abbreviated, time: .omitted))
        if e.allDay { return "\(day) · весь день" }
        let time = "\(e.start.formatted(date: .omitted, time: .shortened))–\(e.end.formatted(date: .omitted, time: .shortened))"
        return [day, time, e.location].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: Timer

struct TimerTab: View {
    @ObservedObject var timer: FocusTimer
    private let presets: [Double] = [1, 3, 5, 10, 15, 25, 45, 60]

    var body: some View {
        HStack(spacing: 10) {
            Card {
                HStack(spacing: 18) {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let remaining = timer.remaining(at: context.date)
                        let fraction = timer.total > 0 ? remaining / timer.total : 0
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.1), lineWidth: 8)
                            Circle().trim(from: 0, to: (timer.isRunning || timer.isPaused) ? fraction : 1)
                                .stroke(color, style: .init(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 2) {
                                Text(FocusTimer.format(remaining)).font(.system(size: 28, weight: .semibold).monospacedDigit())
                                Text(timer.phase.title).font(.system(size: 11)).foregroundStyle(muted)
                            }
                        }
                        .frame(width: 150, height: 150)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if timer.isRunning || timer.isPaused {
                            HStack(spacing: 8) {
                                big(timer.isPaused ? "Продолжить" : "Пауза", filled: true) { timer.pauseResume() }
                                big("Сброс") { timer.reset() }
                            }
                            HStack(spacing: 8) {
                                big("+1 мин") { timer.add(minutes: 1) }
                                big("+5 мин") { timer.add(minutes: 5) }
                            }
                        } else {
                            Text("Выберите время справа").font(.system(size: 12)).foregroundStyle(muted)
                        }
                        if timer.pomodoro {
                            HStack(spacing: 5) {
                                ForEach(0..<4) { i in
                                    Circle().fill(i < timer.completedFocus % 4 || (timer.completedFocus > 0 && timer.completedFocus % 4 == 0 && timer.phase == .longBreak) ? color : Color.white.opacity(0.15))
                                        .frame(width: 8, height: 8)
                                }
                                Text("помодоро: \(timer.completedFocus)").font(.system(size: 10)).foregroundStyle(muted)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Быстрый старт").font(.system(size: 12, weight: .semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(presets, id: \.self) { m in
                            Button { timer.pomodoro = false; timer.start(minutes: m) } label: {
                                Text(m >= 60 ? "1 ч" : "\(Int(m))м").font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button { timer.startPomodoro() } label: {
                        HStack {
                            Image(systemName: "flame.fill")
                            Text("Помодоро 25 / 5").font(.system(size: 12, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 1, green: 0.42, blue: 0.35).opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 250)
        }
    }

    private var color: Color {
        switch timer.phase {
        case .shortBreak, .longBreak: return .green
        case .focus: return Color(red: 1, green: 0.42, blue: 0.35)
        case .plain: return accent
        }
    }

    private func big(_ title: String, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.12)))
                .foregroundStyle(filled ? .black : .white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Cuely

struct CuelyTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var cuely: Cuely

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Сценарии").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button { cuely.newScript() } label: { Image(systemName: "plus") }.buttonStyle(.plain)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(cuely.scripts) { s in
                            Text(s.title).font(.system(size: 11)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 7).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(s.id == cuely.current?.id ? Color.white.opacity(0.14) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { cuely.currentID = s.id }
                                .contextMenu { Button("Удалить") { cuely.delete(s) } }
                        }
                    }
                }
            }
            .frame(width: 150)

            TextEditor(text: Binding(get: { cuely.current?.body ?? "" }, set: { cuely.update(body: $0) }))
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(soft))
                .onTapGesture { model.stayOpen() }

            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $cuely.voiceFollow) {
                    Text("Авто").tag(false)
                    Text("Голос").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                if cuely.voiceFollow {
                    Picker("Язык", selection: $cuely.language) {
                        ForEach(Cuely.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .font(.system(size: 11))
                    Text("Текст идёт за вашей речью. Распознавание на Mac, звук не сохраняется.")
                        .font(.system(size: 9)).foregroundStyle(muted)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Скорость: \(Int(cuely.wordsPerMinute)) слов/мин").font(.system(size: 10)).foregroundStyle(muted)
                        Slider(value: $cuely.wordsPerMinute, in: 60...300, step: 5)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Шрифт: \(Int(cuely.fontSize))").font(.system(size: 10)).foregroundStyle(muted)
                    Slider(value: $cuely.fontSize, in: 16...40, step: 1)
                }
                Spacer(minLength: 0)
                Button { cuely.present(); model.focusPanel() } label: {
                    Label("Начать", systemImage: "play.fill").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white)).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                Text("Пробел — пауза, ←/→ — скорость, Esc — стоп").font(.system(size: 9)).foregroundStyle(muted)
            }
            .frame(width: 190)
        }
    }
}
