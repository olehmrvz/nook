import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Shape

/// Black notch with outward "ears" at the top corners, so it grows out of the camera housing.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat = NotchModel.ear

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, e = ear
        let r = min(bottomRadius, (w - 2 * e) / 2, h / 2)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: e, y: e), control: CGPoint(x: e, y: 0))
        p.addLine(to: CGPoint(x: e, y: h - r))
        p.addQuadCurve(to: CGPoint(x: e + r, y: h), control: CGPoint(x: e, y: h))
        p.addLine(to: CGPoint(x: w - e - r, y: h))
        p.addQuadCurve(to: CGPoint(x: w - e, y: h - r), control: CGPoint(x: w - e, y: h))
        p.addLine(to: CGPoint(x: w - e, y: e))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - e, y: 0))
        p.closeSubpath()
        return p
    }
}

extension NotchModel {
    func dropFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    self.shelf.add([url])
                    self.expand(tab: .shelf)
                }
            }
        }
    }
}

// MARK: Small indicators

/// A looping indicator drawn by Core Animation. The frames run in the window server, so SwiftUI does not
/// re-render (and lay out the whole notch window) on every frame: a TimelineView here cost ~4 % CPU.
/// `build` adds sublayers to the root; `animated` is false while the screens rest or with Reduce Motion.
struct LayerLoop: NSViewRepresentable {
    var key: AnyHashable
    var build: (CALayer, CGSize, Bool) -> Void
    @Environment(\.motionPaused) private var paused

    func makeNSView(context: Context) -> Host { Host() }

    func updateNSView(_ view: Host, context: Context) {
        view.update(key: [key, AnyHashable(paused)], animated: !paused && !Motion.reduce, build: build)
    }

    final class Host: NSView {
        private var key: AnyHashable?
        private var animated = true
        private var build: ((CALayer, CGSize, Bool) -> Void)?
        private var builtSize = CGSize.zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(key: AnyHashable, animated: Bool, build: @escaping (CALayer, CGSize, Bool) -> Void) {
            self.build = build
            self.animated = animated
            guard key != self.key else { return }
            self.key = key
            rebuild()
        }

        override func layout() {
            super.layout()
            if bounds.size != builtSize { rebuild() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            rebuild()
        }

        private func rebuild() {
            guard let layer, window != nil, bounds.width > 0, let build else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            layer.speed = Float(Motion.speed)
            build(layer, bounds.size, animated)
            CATransaction.commit()
            builtSize = bounds.size
        }
    }

    /// One endlessly repeating keyframe loop sampled from `value` over `period` seconds.
    static func loop(_ keyPath: String, period: Double, samples: Int = 30, _ value: (Double) -> Double) -> CAAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = (0...samples).map { value(period * Double($0) / Double(samples)) }
        animation.duration = period
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        return animation
    }
}

/// Music bars in the collapsed notch.
struct Bars: View {
    var color: Color = .white
    var body: some View {
        let cg = NSColor(color.opacity(0.9)).cgColor
        LayerLoop(key: AnyHashable(color)) { root, size, animated in
            for i in 0..<4 {
                let w = 2.2 + Double(i) * 0.7
                let height = { (t: Double) in 14 * (0.35 + 0.65 * abs(sin(t * w + Double(i)))) }
                let bar = CALayer()
                bar.backgroundColor = cg
                bar.cornerRadius = 1.5
                bar.bounds = CGRect(x: 0, y: 0, width: 3, height: height(0))
                bar.position = CGPoint(x: CGFloat(i) * 5.5 + 1.5, y: size.height / 2)
                if animated { bar.add(LayerLoop.loop("bounds.size.height", period: .pi / w, height), forKey: "bars") }
                root.addSublayer(bar)
            }
        }
        .frame(width: 19.5, height: 14)
    }
}

/// Three dots in a soft wave: an agent works.
struct Spinner: View {
    var color: Color = .white
    var speed: Double = 5
    var body: some View {
        let cg = NSColor(color).cgColor
        LayerLoop(key: [AnyHashable(color), AnyHashable(speed)]) { root, size, animated in
            for i in 0..<3 {
                let opacity = { (t: Double) in 0.3 + 0.7 * max(0, sin(t * speed - Double(i) * 0.8)) }
                let dot = CALayer()
                dot.backgroundColor = cg
                dot.cornerRadius = 2.25
                dot.frame = CGRect(x: CGFloat(i) * 7.5, y: (size.height - 4.5) / 2, width: 4.5, height: 4.5)
                dot.opacity = Float(opacity(0))
                if animated { dot.add(LayerLoop.loop("opacity", period: 2 * .pi / speed, opacity), forKey: "wave") }
                root.addSublayer(dot)
            }
        }
        .frame(width: 19.5, height: 4.5)
    }
}

struct Artwork: View {
    var image: NSImage?
    var size: CGFloat
    var radius: CGFloat
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Palette.pink.opacity(0.55), Palette.violet.opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: Home

struct NowPlayingCard: View {
    @ObservedObject var np: NowPlaying
    /// Narrow layout for Home, where agents take the middle.
    var compact = false

    var body: some View {
        let colors = np.glowColors
        Card(tint: np.hasTrack ? [colors[0].opacity(0.26), colors[1].opacity(0.08)] : [], padding: 16) {
            if np.hasTrack { playing(colors).transition(.opacity) } else { idle.transition(.opacity) }
        }
        .animation(Motion.smooth, value: np.hasTrack)
        .animation(Motion.smooth, value: np.title)
        .animation(.easeInOut(duration: 0.6), value: colors)
    }

    private func playing(_ colors: [Color]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: compact ? 13 : 16) {
                Button { np.openPlayer() } label: {
                    Artwork(image: np.artwork, size: compact ? 76 : 96, radius: compact ? 16 : 18)
                        .id(np.artwork)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .shadow(color: colors[0].opacity(0.55), radius: 16, y: 6)
                }
                .buttonStyle(.icon)
                .help("Открыть \(np.source?.name ?? "плеер")")
                VStack(alignment: .leading, spacing: 4) {
                    Caps(text: np.isPlaying ? "Сейчас играет" : "На паузе").contentTransition(.opacity)
                    Text(np.title).font(.system(size: compact ? 16 : 20, weight: .bold)).tracking(-0.3).lineLimit(2)
                        .contentTransition(.opacity)
                    Text(np.artist).font(.system(size: compact ? 12 : 13)).foregroundStyle(muted).lineLimit(1)
                        .contentTransition(.opacity)
                    HStack(spacing: 6) {
                        if let icon = np.sourceIcon {
                            Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                        } else {
                            Circle().fill(np.sourceColor).frame(width: 6, height: 6)
                        }
                        Text(np.source?.name ?? "").font(.system(size: 11, weight: .medium)).foregroundStyle(faint).lineLimit(1)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 10)
            PlaybackProgress(np: np, colors: colors)
            Spacer(minLength: 10)
            HStack(spacing: compact ? 22 : 30) {
                control("backward.fill", np.previous)
                Button(action: np.playPause) {
                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .contentTransition(.symbolEffect(.replace))
                        .animation(Motion.quick, value: np.isPlaying)
                        .shadow(color: .black.opacity(0.25), radius: 2)
                        .frame(width: compact ? 46 : 50, height: compact ? 46 : 50)
                        .background(Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading,
                                                                  endPoint: .bottomTrailing)))
                        .shadow(color: colors[0].opacity(0.5), radius: 12, y: 4)
                }
                .buttonStyle(.icon)
                control("forward.fill", np.next)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var idle: some View {
        VStack(spacing: 10) {
            Badge(symbol: "music.note", colors: Palette.musicGlow, size: 56)
            VStack(spacing: 3) {
                Text("Ничего не играет").font(.system(size: 15, weight: .semibold))
                Text("Музыка из любого приложения появится здесь").font(.system(size: 12)).foregroundStyle(muted)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                Button("Spotify") { np.launch(.spotify) }.buttonStyle(.pill(small: true))
                Button("Музыка") { np.launch(.music) }.buttonStyle(.pill(small: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func control(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 19)).frame(width: 38, height: 34)
        }
        .buttonStyle(.icon)
    }
}

struct PlaybackProgress: View {
    @ObservedObject var np: NowPlaying
    var colors: [Color]
    @State private var dragFraction: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let pos = np.livePosition(at: context.date)
            let fraction = dragFraction ?? (np.duration > 0 ? pos / np.duration : 0)
            let shown = dragFraction.map { $0 * np.duration } ?? pos
            VStack(spacing: 5) {
                GeometryReader { geo in
                    // Polls come every half second; a linear glide between them keeps the knob moving.
                    GlowBar(fraction: fraction, colors: colors, knob: true,
                            animation: dragFraction == nil ? .linear(duration: 0.5) : nil)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { dragFraction = min(max(0, $0.location.x / geo.size.width), 1) }
                            .onEnded { value in
                                np.seek(to: min(max(0, value.location.x / geo.size.width), 1) * np.duration)
                                dragFraction = nil
                            })
                }
                .frame(height: 12)
                HStack {
                    Text(Self.time(shown))
                    Spacer()
                    Text("−" + Self.time(max(0, np.duration - shown)))
                }
                .font(.rounded(11, .medium)).monospacedDigit().foregroundStyle(faint)
            }
        }
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

extension AgentHub.Session {
    /// Sorting: what needs you first, then work in progress.
    var rank: Int {
        switch status {
        case .waiting: return 0
        case .attention: return 1
        case .working: return 2
        case .done: return 3
        case .idle: return 4
        }
    }

    var glyph: String { provider == .claude ? "✳︎" : "◎" }
    var tint: Color { provider == .claude ? Palette.claude : Palette.cyan }
    var needsYou: Bool { status == .waiting || status == .attention }

    /// First word of the second line, in colour: the state at a glance.
    var stateWord: String {
        switch status {
        case .working: return "Работает"
        case .waiting: return "Ждёт разрешения"
        case .attention: return "Ждёт вас"
        case .done: return "Готово"
        case .idle: return "Ожидает"
        }
    }

    var stateColor: Color {
        switch status {
        case .working: return .white
        case .waiting, .attention: return Palette.orange
        case .done: return Palette.green
        case .idle: return faint
        }
    }

    /// The rest of the second line: what is happening now, or how the turn ended.
    var detail: String {
        switch status {
        case .working: return action ?? "думает…"
        case .waiting: return action ?? ""
        case .attention: return note ?? ""
        case .done, .idle: return lastMessage ?? (status == .done ? "ждёт новую задачу" : "")
        }
    }

    var detailIcon: String {
        switch status {
        case .waiting: return "hand.raised.fill"
        case .attention: return "bubble.left.fill"
        case .done: return "checkmark.bubble.fill"
        case .idle: return "moon.zzz.fill"
        case .working:
            switch tool ?? "" {
            case "Bash": return "terminal.fill"
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return "pencil"
            case "Read": return "doc.text.fill"
            case "Grep", "Glob": return "magnifyingglass"
            case "WebFetch", "WebSearch": return "globe"
            case "Task", "Agent": return "person.2.fill"
            case let t where t.hasPrefix("mcp__"): return "puzzlepiece.extension.fill"
            default: return "sparkles"
            }
        }
    }

    /// Working: "идёт 3 мин". Otherwise: "8 мин назад".
    var timeText: String {
        if status == .working, let start = turnStarted { return "идёт " + Format.span(Date().timeIntervalSince(start)) }
        let ago = Date().timeIntervalSince(updated)
        return ago < 5 ? "сейчас" : Format.span(ago) + " назад"
    }
}

/// Status mark used in session lists.
struct SessionIndicator: View {
    let status: AgentHub.Status
    var body: some View {
        switch status {
        case .working: Spinner(color: .white.opacity(0.85))
        // Still, not animated: movement means "working"; amber means "your turn".
        case .waiting, .attention: Circle().fill(Palette.orange).frame(width: 7, height: 7)
        case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.green)
        case .idle: Circle().fill(faint).frame(width: 6, height: 6)
        }
    }
}

/// One agent session: project, branch and time; your request; what it does now or how it ended.
/// Click brings its terminal to the front.
struct SessionBlock: View {
    let session: AgentHub.Session
    var roomy = false
    /// Tokens and cost of the whole session (Claude only).
    var usage: Usage.Total?
    /// Shows "Ответить" when Nook can type into the agent's terminal.
    var onReply: (() -> Void)?
    @State private var hover = false

    var body: some View {
        Button { AgentHub.focus(pid: session.pid, terminal: session.terminal) } label: {
            HStack(alignment: .top, spacing: 9) {
                SessionIndicator(status: session.status)
                    .frame(width: 18, height: 16)
                    .id(session.status)
                    .transition(.scale.combined(with: .opacity))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.project).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let branch = session.branch {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.system(size: 10.5, weight: .medium)).labelStyle(.titleAndIcon)
                                .foregroundStyle(faint).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(session.timeText).font(.rounded(11, .medium)).foregroundStyle(faint)
                            .contentTransition(.numericText())
                    }
                    if let prompt = session.prompt {
                        Text("«\(prompt)»").font(.system(size: 11.5)).foregroundStyle(muted).lineLimit(roomy ? 2 : 1)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: session.detailIcon).font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(session.stateColor)
                        (Text(session.stateWord).fontWeight(.semibold).foregroundColor(session.stateColor)
                         + Text(session.detail.isEmpty ? "" : " · " + session.detail).foregroundColor(.white.opacity(0.72)))
                            .lineLimit(roomy ? 2 : 1)
                        if !session.edited.isEmpty && !roomy {
                            Text("· ✎ \(session.edited.count)").foregroundStyle(.white.opacity(0.6)).fixedSize()
                        }
                    }
                    .font(.system(size: 11))
                    .contentTransition(.opacity)
                    .padding(.trailing, onReply == nil ? 0 : 86)
                    if roomy && (!session.edited.isEmpty || session.toolCount > 0 || session.testsPassed != nil || session.committed
                                 || (usage?.tokens ?? 0) > 0) {
                        Text(Self.workLine(session, usage: usage)).font(.system(size: 10.5)).foregroundStyle(faint).lineLimit(1)
                            .padding(.trailing, onReply == nil ? 0 : 86)
                    }
                }
            }
            .padding(.horizontal, roomy ? 14 : 6).padding(.vertical, roomy ? 10 : 5)
            .background {
                if roomy {
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.clear)
                        .glass(tint: hover ? [Color.white.opacity(0.04)] : [], radius: 16)
                } else if hover {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomTrailing) {
            if let onReply {
                Button(action: onReply) {
                    Label("Ответить", systemImage: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 11, weight: .medium)).labelStyle(.titleAndIcon)
                }
                .buttonStyle(.pill(small: true))
                .padding(.trailing, 10).padding(.bottom, 8)
                .help("Написать агенту прямо отсюда: текст уйдёт в его терминал")
                .transition(.opacity)
            }
        }
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        .animation(Motion.smooth, value: session.status)
        .animation(Motion.smooth, value: session.detail)
        .help(session.terminal?["HERDR_TAB_ID"] != nil ? "Открыть вкладку herdr этой сессии" : "Открыть терминал этой сессии")
    }

    /// "12 действий · изменено: Views.swift, Theme.swift и ещё 2".
    static func workLine(_ s: AgentHub.Session, usage: Usage.Total? = nil) -> String {
        var parts: [String] = []
        if let usage, usage.tokens > 0 {
            parts.append(Format.tokens(usage.tokens) + (usage.cost > 0 ? ", " + Format.dollars(usage.cost) : ""))
        }
        if s.toolCount > 0 { parts.append(Format.count(s.toolCount, "действие", "действия", "действий")) }
        if !s.edited.isEmpty {
            let shown = s.edited.prefix(2).joined(separator: ", ")
            parts.append("изменено: " + shown + (s.edited.count > 2 ? " и ещё \(s.edited.count - 2)" : ""))
        }
        if let passed = s.testsPassed { parts.append(passed ? "тесты ✓" : "тесты ✗") }
        if s.committed { parts.append(s.pushed ? "коммит и push" : "коммит") } else if s.pushed { parts.append("push") }
        return parts.joined(separator: " · ")
    }
}

/// Remaining limit as a tiny ring with the percentage next to it.
struct MiniLimit: View {
    let title: String
    let window: UsageWindow?
    let colors: [Color]

    var body: some View {
        let left = window.map { Int(max(0, 100 - $0.usedPercent).rounded()) }
        HStack(spacing: 4) {
            RingGauge(fraction: Double(left ?? 0) / 100, colors: (left ?? 100) < 15 ? [Palette.red, Palette.orange] : colors,
                      lineWidth: 3.5)
                .frame(width: 18, height: 18)
            Text(left.map { "\($0)%" } ?? "—").font(.rounded(11)).foregroundStyle(.white.opacity(0.85))
                .contentTransition(.numericText())
        }
        .help("\(title): осталось \(left.map { "\($0)%" } ?? "—")"
              + (window?.resetsAt.map { ", сброс " + $0.formatted(.relative(presentation: .named)) } ?? ""))
    }
}

struct AgentsSummary: View {
    @ObservedObject var agents: AgentHub
    @ObservedObject var limits: Limits
    var open: () -> Void

    var body: some View {
        let waiting = agents.sessions.filter(\.needsYou).count
        let working = agents.sessions.filter { $0.status == .working }.count
        let sorted = agents.sessions.sorted { $0.rank < $1.rank || ($0.rank == $1.rank && $0.updated > $1.updated) }
        Card(tint: [Palette.claude.opacity(waiting > 0 ? 0.42 : 0.3), Palette.claude.opacity(0)],
             stroke: waiting > 0 ? Palette.claude.opacity(0.45) : .white.opacity(0.1), padding: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button(action: open) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.claude)
                            Text("Агенты").font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .buttonStyle(.icon)
                    .help("Все сессии  ⌘4")
                    if waiting > 0 {
                        Chip(text: "\(waiting) ждёт", color: accent).transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else if working > 0 {
                        Chip(text: "\(working) в работе", color: Palette.claude).transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    Spacer(minLength: 4)
                    MiniLimit(title: "Claude · 5 ч", window: limits.claudeSession, colors: [Palette.pink, Palette.violet])
                    MiniLimit(title: "Claude · неделя", window: limits.claudeWeek, colors: [Palette.orange, Palette.claude])
                }
                .padding(.horizontal, 2)
                if sorted.isEmpty {
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        Text(agents.hooksInstalled ? "Нет активных сессий" : "Nook не подключён к агентам")
                            .font(.system(size: 13, weight: .medium))
                        Text(agents.hooksInstalled ? "Запущенные Claude Code и Codex появятся здесь"
                                                   : "Откройте вкладку «Агенты», чтобы подключить")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(sorted.prefix(3)) { session in
                            SessionBlock(session: session).transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    Spacer(minLength: 0)
                    if sorted.count > 3 {
                        Button(action: open) {
                            Text("ещё \(sorted.count - 3) · все сессии").font(.system(size: 11)).foregroundStyle(faint)
                        }
                        .buttonStyle(.icon)
                        .padding(.leading, 6)
                    }
                }
            }
            .animation(Motion.smooth, value: agents.sessions.map(\.id))
            .animation(Motion.smooth, value: waiting)
        }
    }
}

/// Facts about a finished turn as small labels: "✎ 3 файла", "✓ тесты прошли", "коммит".
struct TurnFacts: View {
    let facts: [AgentHub.TurnFact]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(facts, id: \.self) { fact in
                HStack(spacing: 3) {
                    Image(systemName: fact.symbol).font(.system(size: 9, weight: .bold))
                    Text(fact.text)
                }
                .foregroundStyle(fact.good == true ? Palette.green : (fact.good == false ? Palette.salmon : .white.opacity(0.7)))
                .fixedSize()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }
}

/// Reply to an agent: one line typed into its terminal (herdr or tmux), Enter included.
struct ReplyField: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var agents: AgentHub
    let session: AgentHub.Session
    @State private var text = ""
    @State private var sending = false
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        let blank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 11)).foregroundStyle(Palette.claude.lifted())
            TextField(failed ? "Не дошло — откройте терминал" : "Что ответить агенту в \(session.project)?", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .focused($focused)
                .onSubmit(send)
            Button(sending ? "Отправляю…" : "Отправить", action: send)
                .buttonStyle(.pill(.primary, small: true))
                .disabled(blank || sending)
            Button { model.replyTo = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(muted).frame(width: 18, height: 18)
            }
            .buttonStyle(.icon)
            .help("Закрыть")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glass(tint: [Palette.claude.opacity(0.18)], stroke: Palette.claude.opacity(0.35), radius: 14)
        .onAppear {
            model.stayOpen()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { focused = true }
        }
    }

    private func send() {
        guard !sending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sending = true
        failed = false
        agents.reply(to: session.id, text: text) { ok in
            sending = false
            if ok {
                text = ""
                model.replyTo = nil
                // Sent: close the panel and give the keyboard back to the app you were in.
                model.collapse()
            } else {
                failed = true
            }
        }
    }
}

// MARK: Clipboard

struct ClipboardTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: ClipboardStore
    @FocusState private var searchFocused: Bool
    @Namespace private var selectionSpace

    var body: some View {
        let items = store.filtered
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(muted)
                TextField("Поиск в буфере", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { if items.indices.contains(store.selection) { model.pick(items[store.selection]) } }
                    .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                    .onKeyPress(.escape) { model.collapse(); return .handled }
                    .onChange(of: store.query) { _, _ in store.selection = 0 }
                if AXIsProcessTrusted() {
                    Text("↩ вставить").font(.system(size: 11)).foregroundStyle(faint)
                } else {
                    // Without Accessibility, ↩ only copies; one click asks macOS for the permission.
                    Button("↩ копирует · включить вставку") {
                        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                    }
                    .buttonStyle(.icon).font(.system(size: 11)).foregroundStyle(faint)
                    .help("Разрешить Nook вставлять выбранное в предыдущее приложение (Универсальный доступ)")
                }
                if store.canUndo {
                    Button("Вернуть") { store.undoRemove() }
                        .buttonStyle(.pill(small: true)).focusable(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Button { store.clearUnpinned() } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 22)
                }
                .buttonStyle(.icon).focusable(false).foregroundStyle(muted).help("Очистить всё, кроме закреплённого (можно вернуть 15 с)")
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
            .glass(radius: 12)
            .entrance(0)

            if items.isEmpty {
                VStack(spacing: 8) {
                    Badge(symbol: store.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass",
                          colors: [Palette.blue, Palette.violet], size: 44)
                    Text(store.query.isEmpty ? "Скопируйте что-нибудь — оно появится здесь" : "Ничего не найдено")
                        .font(.system(size: 12)).foregroundStyle(muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ListScroll {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, store: store, selected: index == store.selection,
                                        selectionSpace: selectionSpace) {
                                    model.pick(item)
                                }
                                .contextMenu {
                                    Button(model.sticky && AXIsProcessTrusted() ? "Вставить" : "Скопировать") { model.pick(item) }
                                    if let url = store.imageURL(for: item) {
                                        Button("Скопировать текст с картинки") {
                                            TextRecognizer.copyText(from: url) { ok in model.show(ok ? .copied : .noText, for: 1.6) }
                                        }
                                    }
                                    Button(item.pinned ? "Открепить" : "Закрепить") { store.togglePin(item) }
                                    Divider()
                                    Button("Удалить") { store.delete(item, source: "menu") }
                                }
                                .id(item.id)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(Motion.quick, value: store.selection)
                        .animation(Motion.smooth, value: items.map(\.id))
                    }
                    .entrance(1)
                    .onChange(of: store.selection) { _, new in
                        if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                    }
                }
            }
        }
        // Focus only when Nook owns the keyboard (opened with ⌃⌘V); otherwise typing stays in your app.
        .onAppear { if model.sticky && model.panel?.isKeyWindow == true { searchFocused = true } }
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        store.selection = min(max(0, store.selection + delta), count - 1)
    }
}

struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var store: ClipboardStore
    let selected: Bool
    let selectionSpace: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.preview.replacingOccurrences(of: "\n", with: " ⏎ "))
                        .font(.system(size: 12.5)).lineLimit(1)
                    Text([item.sourceApp, item.date.formatted(.relative(presentation: .named))]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(faint)
                }
                Spacer(minLength: 0)
                if hover || item.pinned {
                    Button { store.togglePin(item) } label: {
                        Image(systemName: item.pinned ? "pin.fill" : "pin").font(.system(size: 11))
                    }
                    .buttonStyle(.icon).focusable(false).foregroundStyle(item.pinned ? accent : muted).help("Закрепить")
                }
                if hover {
                    Button { store.delete(item, source: "row") } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.icon).focusable(false).foregroundStyle(muted).help("Удалить")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background {
                if selected {
                    // One highlight that slides between rows as the arrows move the selection.
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.clear)
                        .glass(tint: [Palette.blue.opacity(0.28), Palette.violet.opacity(0.1)], radius: 12)
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                } else if hover {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover = $0 }
        .help(item.kind == .text ? String((item.text ?? "").prefix(600)) : item.preview)
    }

    @ViewBuilder private var icon: some View {
        Group {
            switch item.kind {
            case .image:
                if let image = store.thumbnail(for: item) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(muted)
                }
            case .files:
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.files?.first ?? "/")).resizable().padding(2)
            case .text:
                let link = item.text?.hasPrefix("http") == true
                Image(systemName: link ? "link" : "text.alignleft")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(link ? Palette.cyan : muted)
            }
        }
        .frame(width: 30, height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: Shelf

struct ShelfTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var shelf: Shelf
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 10) {
            if shelf.items.isEmpty {
                VStack(spacing: 10) {
                    Badge(symbol: "tray.and.arrow.down.fill", colors: [Palette.cyan, Palette.blue], size: 52)
                    Text("Перетащите файлы на вырез").font(.system(size: 15, weight: .semibold))
                    Text("Новые скриншоты попадают сюда сами").font(.system(size: 12)).foregroundStyle(muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glass()
                .entrance(0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item, shelf: shelf) { ok in model.show(ok ? .copied : .noText, for: 1.6) }
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .padding(.vertical, 2)
                    .animation(Motion.smooth, value: shelf.items.map(\.id))
                }
                .entrance(0)
                HStack(spacing: 8) {
                    Text("\(shelf.items.count) файл(ов) · перетащите наружу, чтобы использовать")
                        .font(.system(size: 11)).foregroundStyle(muted)
                    Spacer()
                    Button { shelf.airDrop(shelf.items.map(\.url)) } label: {
                        Label("AirDrop всё", systemImage: "airplayaudio")
                    }
                    .buttonStyle(.pill(small: true))
                    Button { shelf.clear() } label: { Label("Очистить", systemImage: "trash") }
                        .buttonStyle(.pill(small: true)).focusable(false)
                }
                .entrance(1)
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Palette.cyan, style: .init(lineWidth: 2, dash: [7, 5]))
                    .shadow(color: Palette.cyan.opacity(0.6), radius: 10)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { shelf.add([url]) } }
                }
            }
            return true
        }
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    @ObservedObject var shelf: Shelf
    /// Feedback after "copy text": true when some text was found.
    var copiedText: (Bool) -> Void = { _ in }
    @State private var hover = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = shelf.thumbnails[item.path] {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().scaledToFit()
                    }
                }
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                if hover {
                    HStack(spacing: 4) {
                        tileButton("airplayaudio") { shelf.airDrop([item.url]) }
                        tileButton("xmark") { shelf.remove(item) }
                    }
                    .offset(x: 4, y: -4)
                }
            }
            Text(item.name).font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle).frame(width: 112)
        }
        .padding(8)
        .glass(tint: hover ? [Palette.cyan.opacity(0.18), Palette.blue.opacity(0.06)] : [], radius: 16)
        .scaleEffect(hover && !Motion.reduce ? 1.02 : 1)
        .animation(Motion.quick, value: hover)
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { shelf.open(item) }
        .contextMenu {
            Button("Открыть") { shelf.open(item) }
            Button("Скопировать") { shelf.copy(item) }
            if UTType(filenameExtension: item.url.pathExtension)?.conforms(to: .image) == true {
                Button("Скопировать текст с картинки") { TextRecognizer.copyText(from: item.url, done: copiedText) }
            }
            Button("Показать в Finder") { shelf.reveal(item) }
            Button("AirDrop") { shelf.airDrop([item.url]) }
            Divider()
            Button("Убрать с полки") { shelf.remove(item) }
        }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .help(item.path)
    }

    private func tileButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 22).background(Circle().fill(Color(white: 0.22)))
                .overlay(Circle().strokeBorder(.white.opacity(0.15)))
        }
        .buttonStyle(.icon)
    }
}

// MARK: Agents

struct AgentsTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var agents: AgentHub
    @ObservedObject var limits: Limits
    @ObservedObject var usage: Usage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if agents.permissions.isEmpty && agents.sessions.isEmpty {
                    Card {
                        VStack(spacing: 8) {
                            Badge(symbol: "sparkles", colors: [Palette.claude, Palette.orange], size: 48)
                            Text("Нет активных сессий").font(.system(size: 15, weight: .semibold))
                            Text(agents.hooksInstalled
                                 ? "Запустите Claude Code или Codex — статус и запросы на разрешение появятся здесь"
                                 : "Nook ещё не подключён к Claude Code и Codex")
                                .font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center)
                            if !agents.hooksInstalled {
                                Button("Подключить") {
                                    _ = AgentHub.installHooks()
                                    agents.checkHooks()
                                }
                                .buttonStyle(.pill(.primary, small: true))
                                .help("Добавит хук Nook в ~/.claude/settings.json и ~/.codex/hooks.json, сохранив копии файлов")
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 6) {
                        // The oldest request stays pinned and whole; no scrolling to reach its buttons.
                        if let request = agents.permissions.first {
                            RequestCard(request: request, agents: agents, more: agents.permissions.count - 1)
                                .id(request.id)
                                .transition(.asymmetric(insertion: .scale(scale: 0.95, anchor: .top).combined(with: .opacity),
                                                        removal: .scale(scale: 0.97).combined(with: .opacity)))
                        }
                        ListScroll {
                            VStack(spacing: 6) {
                                ForEach(agents.sessions.sorted { $0.rank < $1.rank }) { session in
                                    let canReply = agents.canReply(session)
                                    VStack(spacing: 4) {
                                        SessionBlock(session: session, roomy: true, usage: usage.total(for: session),
                                                     onReply: canReply ? { model.startReply(to: session.id) } : nil)
                                        if canReply && model.replyTo == session.id {
                                            ReplyField(model: model, agents: agents, session: session)
                                                .transition(.opacity.combined(with: .move(edge: .top)))
                                        }
                                    }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .animation(Motion.smooth, value: agents.sessions.map(\.id))
                            .animation(Motion.smooth, value: model.replyTo)
                        }
                    }
                    .animation(Motion.smooth, value: agents.permissions.map(\.id))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .entrance(0)
            LimitsCard(limits: limits, usage: usage).frame(width: 236).entrance(1)
        }
    }
}

/// The right card for a pending request: a question, a plan, or a plain permission.
struct RequestCard: View {
    let request: AgentHub.Permission
    @ObservedObject var agents: AgentHub
    var more = 0
    var body: some View {
        switch request.tool {
        case "AskUserQuestion": QuestionCard(request: request, agents: agents, more: more)
        case "ExitPlanMode": PlanCard(request: request, agents: agents, more: more)
        default: PermissionCard(request: request, agents: agents, more: more)
        }
    }
}

struct PermissionCard: View {
    let request: AgentHub.Permission
    @ObservedObject var agents: AgentHub
    /// Requests waiting behind this one.
    var more = 0
    /// Buttons wake up a moment after the card appears, so a click meant for something else cannot approve.
    @State private var armed = false

    var body: some View {
        let claude = request.provider == .claude
        let tint = claude ? Palette.claude : Palette.blue
        let lines = request.summary.split(whereSeparator: \.isNewline).count
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Text(claude ? "✳︎" : "◎").font(.system(size: 15, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(tint.opacity(0.35)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(request.project) · \(request.tool)").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text("\(request.provider.title) просит разрешение · \(request.created.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if lines > 1 { Chip(text: "\(lines) строк", color: Palette.orange) }
                if more > 0 { Chip(text: "ещё \(more)", color: .white) }
            }
            // The whole input, scrollable: what you approve is exactly what you can read here.
            ScrollView(showsIndicators: true) {
                Text(request.summary)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 84)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.4)))
            HStack(spacing: 8) {
                Button("Разрешить") { agents.answer(request.id, with: .allow) }.buttonStyle(.pill(.primary))
                if request.suggestions != nil {
                    Button("Всегда") { agents.answer(request.id, with: .always) }.buttonStyle(.pill())
                        .help("Добавит: " + Self.describe(request.suggestions))
                }
                Button("Отклонить") { agents.answer(request.id, with: .deny) }.buttonStyle(.pill(foreground: Palette.salmon))
                Spacer()
                TerminalButton { agents.answer(request.id, with: nil) }
            }
            .disabled(!armed)
            .opacity(armed ? 1 : 0.55)
            if request.suggestions != nil {
                Text("«Всегда» добавит: " + Self.describe(request.suggestions))
                    .font(.system(size: 10.5)).foregroundStyle(faint).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(14)
        .glass(tint: [tint.opacity(0.5), Palette.orange.opacity(0.1)], stroke: tint.opacity(0.55), radius: 22)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation(Motion.quick) { armed = true } } }
    }

    /// Human words for Claude's permission_suggestions: rules, mode switch, extra folders, and where they go.
    static func describe(_ suggestions: Any?) -> String {
        let places = ["localSettings": "этот проект, только у вас", "projectSettings": "проект",
                      "userSettings": "все проекты", "session": "до конца сессии"]
        let parts = (suggestions as? [[String: Any]] ?? []).map { s -> String in
            let place = places[s["destination"] as? String ?? ""] ?? (s["destination"] as? String ?? "")
            switch s["type"] as? String {
            case "addRules", "replaceRules":
                let rules = (s["rules"] as? [[String: Any]] ?? []).map { r in
                    let tool = r["toolName"] as? String ?? "?"
                    return (r["ruleContent"] as? String).map { "\(tool)(\($0))" } ?? tool
                }
                return rules.joined(separator: ", ") + (place.isEmpty ? "" : " → \(place)")
            case "setMode": return "режим \(s["mode"] as? String ?? "?")" + (place.isEmpty ? "" : " → \(place)")
            case "addDirectories":
                let dirs = (s["directories"] as? [String] ?? []).map { ($0 as NSString).lastPathComponent }
                return "доступ к папкам: " + dirs.joined(separator: ", ")
            default: return s["type"] as? String ?? "правило"
            }
        }
        return parts.isEmpty ? "правило из предложения Claude" : parts.joined(separator: "; ")
    }
}

struct LimitsCard: View {
    @ObservedObject var limits: Limits
    @ObservedObject var usage: Usage

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Лимиты · осталось").font(.system(size: 13, weight: .semibold))
                LimitRow(title: "Claude · 5 ч", window: limits.claudeSession, length: 5 * 3600)
                LimitRow(title: "Claude · неделя", window: limits.claudeWeek, length: 7 * 86400)
                LimitRow(title: codexTitle, window: limits.codexPrimary,
                         length: limits.codexWindowMinutes > 0 ? Double(limits.codexWindowMinutes) * 60 : nil)
                Spacer(minLength: 0)
                if usage.today.tokens > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("Сегодня").font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 2)
                        Text(Format.tokens(usage.today.tokens)).font(.rounded(11)).foregroundStyle(.white.opacity(0.85))
                        Text(Format.dollars(usage.today.cost)).font(.rounded(11)).foregroundStyle(faint)
                    }
                    .lineLimit(1)
                    .help("Claude за сегодня: \(Format.tokens(usage.today.tokens)). Стоимость по ценам API"
                          + (usage.today.unpriced ? " (без моделей с неизвестной ценой)" : "")
                          + "; с подпиской Claude платите не вы, это ориентир.")
                }
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.85)).frame(width: 2, height: 9)
                    Text("— остаток при ровном темпе").font(.system(size: 10)).foregroundStyle(faint)
                }
            }
        }
    }

    private var codexTitle: String {
        let m = limits.codexWindowMinutes
        if m >= 10000 { return "Codex · месяц" }
        if m >= 1440 { return "Codex · неделя" }
        return m > 0 ? "Codex · \(m / 60) ч" : "Codex"
    }
}

/// One usage window: what is left, when it resets, and whether spending runs ahead of time.
struct LimitRow: View {
    let title: String
    let window: UsageWindow?
    /// Window length in seconds, for the even-pace mark; nil when unknown.
    let length: TimeInterval?

    var body: some View {
        let left = window.map { max(0, 100 - $0.usedPercent) }
        let timeLeft = window?.resetsAt.map { max(0, $0.timeIntervalSinceNow) }
        // Where the remaining share would be if usage followed the clock.
        let pace = timeLeft.flatMap { t in length.map { min(1, t / $0) } }
        let fast = pace.map { p in (left ?? 100) / 100 < p - 0.15 } ?? false
        let color: [Color] = (left ?? 100) < 10 ? [Palette.red, Palette.coral]
            : ((left ?? 100) < 25 || fast) ? [Palette.orange, Palette.yellow] : [Palette.green, Palette.mint]
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(left.map { "\(Int($0.rounded()))%" } ?? "—").font(.rounded(13))
                    .foregroundStyle(fast ? Palette.orange : .white)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    GlowBar(fraction: (left ?? 0) / 100, colors: color, height: 5)
                    if let pace {
                        RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.85))
                            .frame(width: 2, height: 9)
                            .offset(x: max(0, min(geo.size.width - 2, geo.size.width * pace - 1)))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 9)
            HStack {
                Text(window?.resetsAt.map { "сброс " + Format.when($0) } ?? (window == nil ? "нет данных" : "время сброса неизвестно"))
                Spacer(minLength: 4)
                if let timeLeft { Text("через " + Format.until(timeLeft)) }
            }
            .font(.system(size: 10.5)).foregroundStyle(faint).lineLimit(1)
        }
        .help(fast ? "Расход опережает время: при таком темпе лимит закончится раньше сброса." : title)
    }
}
