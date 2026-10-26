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

let accent = Color(red: 1.0, green: 0.62, blue: 0.2)
let soft = Color.white.opacity(0.08)
let muted = Color.white.opacity(0.55)

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

struct Bars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4) { i in
                    let v = 0.35 + 0.65 * abs(sin(t * (2.2 + Double(i) * 0.7) + Double(i)))
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: 3, height: 14 * v)
                }
            }
            .frame(height: 14)
        }
    }
}

struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.white)
                        .frame(width: 4.5, height: 4.5)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
        }
    }
}

struct PulseDot: View {
    var color: Color
    var body: some View {
        TimelineView(.animation) { context in
            let v = (sin(context.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
            Circle().fill(color).frame(width: 9, height: 9)
                .shadow(color: color.opacity(0.9), radius: 3 + 4 * v)
                .opacity(0.6 + 0.4 * v)
        }
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
                    LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(muted)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(soft))
    }
}

// MARK: Home

struct NowPlayingCard: View {
    @ObservedObject var np: NowPlaying
    var body: some View {
        Card {
            if np.hasTrack {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button { np.openPlayer() } label: { Artwork(image: np.artwork, size: 74, radius: 12) }
                            .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(np.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                            Text(np.artist).font(.system(size: 13)).foregroundStyle(muted).lineLimit(1)
                            Text(np.player?.rawValue ?? "").font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        Spacer(minLength: 0)
                    }
                    PlaybackProgress(np: np)
                    HStack(spacing: 30) {
                        control("backward.fill", np.previous)
                        control(np.isPlaying ? "pause.fill" : "play.fill", np.playPause, size: 24)
                        control("forward.fill", np.next)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note").font(.system(size: 26)).foregroundStyle(muted)
                    Text("Ничего не играет").font(.system(size: 13, weight: .medium))
                    Text("Включите Spotify или Музыку").font(.system(size: 11)).foregroundStyle(muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func control(_ icon: String, _ action: @escaping () -> Void, size: CGFloat = 17) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size)).frame(width: 36, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PlaybackProgress: View {
    @ObservedObject var np: NowPlaying
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let pos = np.livePosition(at: context.date)
            let fraction = np.duration > 0 ? pos / np.duration : 0
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Color.white).frame(width: geo.size.width * fraction)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        np.seek(to: Double(location.x / geo.size.width) * np.duration)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(Self.time(pos))
                    Spacer()
                    Text("−" + Self.time(max(0, np.duration - pos)))
                }
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(muted)
            }
        }
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct AgentsSummary: View {
    @ObservedObject var agents: AgentHub
    var open: () -> Void
    var body: some View {
        Button(action: open) {
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 18))
                        .foregroundStyle(agents.permissions.isEmpty ? .white : accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Агенты").font(.system(size: 13, weight: .semibold))
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                    }
                    Spacer()
                    switch agents.indicator {
                    case .waiting: PulseDot(color: accent)
                    case .working: Spinner()
                    case nil: EmptyView()
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if !agents.permissions.isEmpty { return "Ждут разрешения: \(agents.permissions.count)" }
        let working = agents.sessions.filter { $0.status == .working }.count
        if working > 0 { return "Работают: \(working)" }
        return agents.sessions.isEmpty ? "Нет активных сессий" : "Сессий: \(agents.sessions.count)"
    }
}

struct ShelfSummary: View {
    @ObservedObject var shelf: Shelf
    @ObservedObject var clipboard: ClipboardStore
    var open: (Tab) -> Void
    var body: some View {
        HStack(spacing: 10) {
            tile(icon: "tray.full.fill", title: "Полка", value: "\(shelf.items.count) файл.", tab: .shelf)
            tile(icon: "doc.on.clipboard.fill", title: "Буфер", value: "⌃⌘V", tab: .clipboard)
        }
    }

    private func tile(icon: String, title: String, value: String, tab: Tab) -> some View {
        Button { open(tab) } label: {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: icon).font(.system(size: 16))
                    Spacer(minLength: 0)
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(value).font(.system(size: 11)).foregroundStyle(muted)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: Clipboard

struct ClipboardTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var store: ClipboardStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        let items = store.filtered
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                TextField("Поиск в буфере", text: $store.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if items.indices.contains(store.selection) { model.pick(items[store.selection]) } }
                    .onKeyPress(.downArrow) { move(1, count: items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: items.count); return .handled }
                    .onKeyPress(.escape) { model.collapse(); return .handled }
                    .onChange(of: store.query) { _, _ in store.selection = 0 }
                Text(AXIsProcessTrusted() ? "↩ вставить" : "↩ скопировать")
                    .font(.system(size: 10)).foregroundStyle(muted)
                Button { store.clearUnpinned() } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(muted).help("Очистить всё, кроме закреплённого")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(soft))

            if items.isEmpty {
                Text(store.query.isEmpty ? "Скопируйте что-нибудь — оно появится здесь" : "Ничего не найдено")
                    .font(.system(size: 12)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ClipRow(item: item, store: store, selected: index == store.selection) {
                                    model.pick(item)
                                }
                                .id(item.id)
                            }
                        }
                    }
                    .onChange(of: store.selection) { _, new in
                        if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                    }
                }
            }
        }
        .onAppear { if model.sticky { searchFocused = true } }
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
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.preview.replacingOccurrences(of: "\n", with: " ⏎ "))
                        .font(.system(size: 12)).lineLimit(1)
                    Text([item.sourceApp, item.date.formatted(.relative(presentation: .named))]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer(minLength: 0)
                if hover || item.pinned {
                    Button { store.togglePin(item) } label: {
                        Image(systemName: item.pinned ? "pin.fill" : "pin").font(.system(size: 11))
                    }
                    .buttonStyle(.plain).foregroundStyle(item.pinned ? accent : muted).help("Закрепить")
                }
                if hover {
                    Button { store.delete(item) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(muted).help("Удалить")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected || hover ? Color.white.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .image:
            if let image = store.image(for: item) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else { Image(systemName: "photo") }
        case .files:
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.files?.first ?? "/")).resizable()
        case .text:
            Image(systemName: item.text?.hasPrefix("http") == true ? "link" : "text.alignleft")
                .foregroundStyle(muted)
        }
    }
}

// MARK: Shelf

struct ShelfTab: View {
    @ObservedObject var shelf: Shelf
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 8) {
            if shelf.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 28)).foregroundStyle(muted)
                    Text("Перетащите файлы на вырез").font(.system(size: 13, weight: .medium))
                    Text("Новые скриншоты попадают сюда сами").font(.system(size: 11)).foregroundStyle(muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in ShelfTile(item: item, shelf: shelf) }
                    }
                    .padding(.vertical, 4)
                }
                HStack(spacing: 14) {
                    Text("\(shelf.items.count) файл(ов) · перетащите наружу, чтобы использовать")
                        .font(.system(size: 11)).foregroundStyle(muted)
                    Spacer()
                    Button { shelf.airDrop(shelf.items.map(\.url)) } label: {
                        Label("AirDrop всё", systemImage: "airplayaudio").font(.system(size: 11))
                    }
                    Button { shelf.clear() } label: { Label("Очистить", systemImage: "trash").font(.system(size: 11)) }
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(targeted ? accent : .clear, style: .init(lineWidth: 2, dash: [6])))
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
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = shelf.thumbnails[item.path] {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "doc")
                    }
                }
                .frame(width: 96, height: 96)
                if hover {
                    HStack(spacing: 4) {
                        tileButton("airplayaudio") { shelf.airDrop([item.url]) }
                        tileButton("xmark") { shelf.remove(item) }
                    }
                    .offset(x: 6, y: -6)
                }
            }
            Text(item.name).font(.system(size: 10)).lineLimit(1).truncationMode(.middle).frame(width: 104)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Color.white.opacity(0.1) : .clear))
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { shelf.open(item) }
        .contextMenu {
            Button("Открыть") { shelf.open(item) }
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
                .frame(width: 20, height: 20).background(Circle().fill(Color(white: 0.25)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: Agents

struct AgentsTab: View {
    @ObservedObject var agents: AgentHub
    @ObservedObject var limits: Limits

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 8) {
                if agents.permissions.isEmpty && agents.sessions.isEmpty {
                    Card {
                        VStack(spacing: 6) {
                            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(muted)
                            Text("Нет активных сессий").font(.system(size: 13, weight: .medium))
                            Text("Запустите Claude Code или Codex — статус и запросы на разрешение появятся здесь")
                                .font(.system(size: 11)).foregroundStyle(muted).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(agents.permissions) { PermissionCard(request: $0, agents: agents) }
                            ForEach(agents.sessions) { SessionRow(session: $0) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            LimitsCard(limits: limits).frame(width: 210)
        }
    }
}

struct PermissionCard: View {
    let request: AgentHub.Permission
    @ObservedObject var agents: AgentHub

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PulseDot(color: accent)
                Text("\(request.provider.title) · \(request.project)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(request.tool).font(.system(size: 11, weight: .medium)).foregroundStyle(accent)
            }
            Text(request.summary)
                .font(.system(size: 11, design: .monospaced)).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                .textSelection(.enabled)
            HStack(spacing: 8) {
                button("Разрешить", filled: true) { agents.answer(request.id, with: .allow) }
                if request.suggestions != nil {
                    button("Всегда") { agents.answer(request.id, with: .always) }
                }
                button("Отклонить") { agents.answer(request.id, with: .deny) }
                Spacer()
                Button("в терминале") { agents.answer(request.id, with: nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(muted)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.5)))
    }

    private func button(_ title: String, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.12)))
                .foregroundStyle(filled ? .black : .white)
        }
        .buttonStyle(.plain)
    }
}

struct SessionRow: View {
    let session: AgentHub.Session
    var body: some View {
        HStack(spacing: 10) {
            Text(session.provider == .claude ? "✳︎" : "◎").font(.system(size: 15))
                .foregroundStyle(session.provider == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : .white)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
            }
            Spacer()
            switch session.status {
            case .working: Spinner()
            case .waiting, .attention: PulseDot(color: accent)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .idle: EmptyView()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(soft))
    }

    private var status: String {
        switch session.status {
        case .working: return session.tool.map { "Работает · \($0)" } ?? "Думает…"
        case .waiting: return "Ждёт разрешения"
        case .attention: return "Ждёт вашего ответа"
        case .done: return "Готово · " + session.updated.formatted(.relative(presentation: .named))
        case .idle: return "Ожидает"
        }
    }
}

struct LimitsCard: View {
    @ObservedObject var limits: Limits
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Лимиты").font(.system(size: 13, weight: .semibold))
                row("Claude · 5 ч", limits.claudeSession)
                row("Claude · неделя", limits.claudeWeek)
                row(codexTitle, limits.codexPrimary)
                Spacer(minLength: 0)
            }
        }
    }

    private var codexTitle: String {
        let m = limits.codexWindowMinutes
        if m >= 10000 { return "Codex · месяц" }
        if m >= 1440 { return "Codex · неделя" }
        return m > 0 ? "Codex · \(m / 60) ч" : "Codex"
    }

    private func row(_ title: String, _ window: UsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(window.map { "\(Int(max(0, 100 - $0.usedPercent).rounded()))% осталось" } ?? "нет данных")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(muted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(color(window?.usedPercent ?? 0))
                        .frame(width: geo.size.width * min(1, (window?.usedPercent ?? 0) / 100))
                }
            }
            .frame(height: 5)
            if let reset = window?.resetsAt {
                Text("сброс " + reset.formatted(.relative(presentation: .named)))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func color(_ used: Double) -> Color {
        used >= 90 ? .red : used >= 70 ? accent : .green
    }
}
