import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Shape

/// Black notch with outward "ears" at the top corners, so it grows out of the camera housing.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat = NotchModel.ear

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, ear) }
        set { bottomRadius = newValue.first; ear = newValue.second }
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

/// The project's first letter in a terminal cell (Figma «3+5 · А · Курсор на букве»). While the agent works, the
/// cursor, a block in the project's colour, slowly fades out and back on the letter; it comes in with a short
/// flash. Not blinking (a request waits for you): the block stays lit. Two projects at work: two letters, the
/// cursor on the last one (it acted last).
struct AgentCursor: View {
    var projects: [String]
    var blinking = true

    /// Lit 1.4 s, fades out in 0.4 s, off 0.4 s, back in 0.4 s.
    private static let blinkPeriod = 2.6
    private static func blink(_ t: Double) -> Double {
        let p = t.truncatingRemainder(dividingBy: blinkPeriod)
        let ease = { (x: Double) in 0.5 - 0.5 * cos(.pi * x) }
        if p < 1.4 { return 1 }
        if p < 1.8 { return 1 - ease((p - 1.4) / 0.4) }
        if p < 2.2 { return 0 }
        return ease((p - 2.2) / 0.4)
    }

    private static let cell = CGSize(width: 11, height: 15)
    private static let gap: CGFloat = 1.5
    /// No yellow, pink, green or red: those mean "waits for you", focus, "done" and errors.
    private static let colors = [Color(hex: 0xB9A4FF), Color(hex: 0x63E6BE), Color(hex: 0x9CC4FF), Color(hex: 0x5ED3D3),
                                 Color(hex: 0xC9D4E4)]

    static func letter(_ project: String) -> String {
        project.first { $0.isLetter || $0.isNumber }.map { String(String($0).uppercased().prefix(1)) } ?? "•"
    }

    /// The same colour for a project every launch (`String.hashValue` is not stable).
    static func color(_ project: String) -> Color {
        let hash = project.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return colors[Int(hash % UInt32(colors.count))]
    }

    var body: some View {
        let cells = projects.suffix(2).map { (Self.letter($0), NSColor(Self.color($0))) }
        LayerLoop(key: [AnyHashable(projects), AnyHashable(blinking)]) { root, size, animated in
            let scale = max(root.contentsScale, 2)
            for (i, (letter, color)) in cells.enumerated() {
                let frame = CGRect(x: CGFloat(i) * (Self.cell.width + Self.gap), y: (size.height - Self.cell.height) / 2,
                                   width: Self.cell.width, height: Self.cell.height)
                let active = i == cells.count - 1
                // What shows while the block is off: the letter in its colour.
                root.addSublayer(Self.text(letter, color: active ? color : color.withAlphaComponent(0.55), in: frame, scale: scale))
                guard active else { continue }
                let cursor = CALayer()
                cursor.frame = frame
                cursor.backgroundColor = color.cgColor
                cursor.cornerRadius = 2
                cursor.addSublayer(Self.text(letter, color: .black, in: cursor.bounds, scale: scale))
                if animated {
                    if blinking { cursor.add(LayerLoop.loop("opacity", period: Self.blinkPeriod, samples: 52, Self.blink), forKey: "blink") }
                    cursor.shadowColor = color.cgColor
                    cursor.shadowRadius = 4
                    cursor.shadowOffset = .zero
                    let flash = CABasicAnimation(keyPath: "shadowOpacity")
                    flash.fromValue = 0.9
                    flash.toValue = 0
                    flash.duration = 0.6
                    cursor.add(flash, forKey: "flash")
                }
                root.addSublayer(cursor)
            }
        }
        .frame(width: CGFloat(cells.count) * Self.cell.width + CGFloat(max(0, cells.count - 1)) * Self.gap,
               height: Self.cell.height)
    }

    /// CATextLayer draws from its top: the line is placed so that the capital sits in the middle of the cell.
    private static func text(_ letter: String, color: NSColor, in frame: CGRect, scale: CGFloat) -> CATextLayer {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let layer = CATextLayer()
        layer.string = letter
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = color.cgColor
        layer.alignmentMode = .center
        layer.contentsScale = scale
        let baseline = frame.minY + (frame.height - font.capHeight) / 2
        layer.frame = CGRect(x: frame.minX, y: baseline + font.descender, width: frame.width,
                             height: ceil(font.ascender - font.descender))
        return layer
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
    var needsYou: Bool { status == .waiting || status == .attention }

    /// First word of the second line, in colour: the state at a glance.
    var stateWord: String {
        switch status {
        case .working: return L("Работает")
        case .waiting: return L("Ждёт разрешения")
        case .attention: return L("Ждёт вас")
        case .done: return L("Готово")
        case .idle: return L("Ожидает")
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
        case .working: return action ?? L("думает…")
        case .waiting: return action ?? ""
        case .attention: return note ?? ""
        case .done, .idle: return lastMessage ?? (status == .done ? L("ждёт новую задачу") : "")
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
        if status == .working, let start = turnStarted { return L("идёт ") + Format.span(Date().timeIntervalSince(start)) }
        let ago = Date().timeIntervalSince(updated)
        return ago < 5 ? L("сейчас") : Format.span(ago) + L(" назад")
    }
}

/// Status mark used in session lists.
struct SessionIndicator: View {
    let status: AgentHub.Status
    var body: some View {
        switch status {
        case .working: Spinner(color: .white.opacity(0.85))
        // Still, not animated: movement means "working"; amber means "your turn".
        case .waiting, .attention: Circle().fill(Tone.attention).frame(width: 7, height: 7)
        case .done: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.green)
        case .idle: Circle().fill(faint).frame(width: 6, height: 6)
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
            Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 11)).foregroundStyle(Tone.ink)
            TextField(failed ? L("Не дошло — откройте терминал") : L("Что ответить агенту в \(session.project)?"), text: $text)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .focused($focused)
                .onSubmit(send)
            Button(sending ? L("Отправляю…") : L("Отправить"), action: send)
                .buttonStyle(.pill(.primary, small: true))
                .disabled(blank || sending)
            Button { model.replyTo = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(muted).frame(width: 18, height: 18)
            }
            .buttonStyle(.icon)
            .help("Закрыть")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Surface.raised)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12))))
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

// MARK: Agents

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
    @State private var textHeight: CGFloat = 0
    private static let lineHeight = NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 12, weight: .regular))

    var body: some View {
        // Lines as drawn, wrapped ones included: one long line can reach far below the visible part too.
        let lines = max(request.summary.split(whereSeparator: \.isNewline).count, Int((textHeight / Self.lineHeight).rounded()))
        VStack(alignment: .leading, spacing: 8) {
            RequestHeader(request: request, title: L("ждёт разрешения"), more: more) {
                if lines > 1 { Chip(text: L("\(lines) строк"), color: Tone.attention) }
            }
            // The whole input, scrollable: what you approve is exactly what you can read here.
            ScrollView(showsIndicators: true) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if request.tool == "Bash" { Text("$").foregroundStyle(.white.opacity(0.4)) }
                    Text(request.summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(GeometryReader { geometry in
                            Color.clear
                                .onAppear { textHeight = geometry.size.height }
                                .onChange(of: geometry.size.height) { _, height in textHeight = height }
                        })
                        .textSelection(.enabled)
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(hex: 0xF2F2F5))
                .padding(.horizontal, 10).padding(.vertical, 7)
            }
            .frame(maxHeight: 58)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
            HStack(spacing: 6) {
                Button("Разрешить") { agents.answer(request.id, with: .allow) }.buttonStyle(.pill(.primary, small: true))
                if request.suggestions != nil {
                    Button("Всегда") { agents.answer(request.id, with: .always) }.buttonStyle(.pill(.ghost, small: true))
                        .help(L("Добавит: ") + Self.describe(request.suggestions))
                }
                Button("Отклонить") { agents.answer(request.id, with: .deny) }.buttonStyle(.pill(.deny, small: true))
                Spacer()
                TerminalButton { agents.answer(request.id, with: nil) }
            }
            .disabled(!armed)
            .opacity(armed ? 1 : 0.55)
            if request.suggestions != nil {
                Text(L("«Всегда» добавит: ") + Self.describe(request.suggestions))
                    .font(.system(size: 10.5)).foregroundStyle(faint).lineLimit(1).truncationMode(.middle)
            }
        }
        .requestCard()
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation(Motion.quick) { armed = true } } }
    }

    /// Human words for Claude's permission_suggestions: rules, mode switch, extra folders, and where they go.
    static func describe(_ suggestions: Any?) -> String { AgentHub.revealed(words(for: suggestions)) }

    private static func words(for suggestions: Any?) -> String {
        let places = ["localSettings": L("этот проект, только у вас"), "projectSettings": L("проект"),
                      "userSettings": L("все проекты"), "session": L("до конца сессии")]
        let parts = (suggestions as? [[String: Any]] ?? []).map { s -> String in
            let place = places[s["destination"] as? String ?? ""] ?? (s["destination"] as? String ?? "")
            switch s["type"] as? String {
            case "addRules", "replaceRules":
                let rules = (s["rules"] as? [[String: Any]] ?? []).map { r in
                    let tool = r["toolName"] as? String ?? "?"
                    return (r["ruleContent"] as? String).map { "\(tool)(\($0))" } ?? tool
                }
                return rules.joined(separator: ", ") + (place.isEmpty ? "" : " → \(place)")
            case "setMode": return L("режим \(s["mode"] as? String ?? "?")") + (place.isEmpty ? "" : " → \(place)")
            case "addDirectories":
                // The whole path: "me" alone would hide that this is the entire home folder.
                let dirs = (s["directories"] as? [String] ?? []).map { ($0 as NSString).abbreviatingWithTildeInPath }
                return L("доступ к папкам: ") + dirs.joined(separator: ", ")
            default: return s["type"] as? String ?? L("правило")
            }
        }
        return parts.isEmpty ? L("правило из предложения Claude") : parts.joined(separator: "; ")
    }
}
