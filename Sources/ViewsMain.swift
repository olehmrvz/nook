import AppKit
import SwiftUI

// MARK: Root

/// `defaults write dev.nook.app slowMotion -float 8` slows every notch animation down for inspection.
enum Motion {
    static let speed: Double = {
        let factor = UserDefaults.standard.double(forKey: "slowMotion")
        return factor > 1 ? 1 / factor : 1
    }()

    /// Respect "Reduce motion": no breathing glow, no staggered cards, no fills from zero.
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Tab switches: the active pill slides, content cross-fades.
    static var tab: Animation { .spring(response: 0.32, dampingFraction: 0.86).speed(speed) }
    /// Cards, lists, rings: soft, no overshoot.
    static var smooth: Animation { .spring(response: 0.45, dampingFraction: 0.88).speed(speed) }
    /// Hover, press, selection.
    static var quick: Animation { .spring(response: 0.28, dampingFraction: 0.9).speed(speed) }
}

/// Content of the panel comes into focus: from a light blur and slightly smaller to sharp.
private struct Materialize: ViewModifier {
    var amount: Double
    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: 6 * amount)
            .scaleEffect(1 - 0.03 * amount, anchor: .top)
    }
}

extension NotchModel {
    func select(_ tab: Tab) {
        withAnimation(Motion.tab) { self.tab = tab }
    }

    /// Light behind the expanded panel: the cover of the playing track, Claude waiting, or the tab's own pair.
    var ambient: [Glow] {
        let waiting = !agents.permissions.isEmpty
        switch tab {
        case .home:
            let right = waiting
                ? Glow(color: Palette.claude, x: 0.8, y: 0.85, size: 460, opacity: 0.55)
                : Glow(color: Palette.blue, x: 0.84, y: 0.92, size: 420, opacity: 0.3)
            if nowPlaying.hasTrack {
                let c = nowPlaying.glowColors
                return [Glow(color: c[0], x: 0.12, y: 0.62, size: 520, opacity: 0.65),
                        Glow(color: c[1], x: 0.36, y: 0.82, size: 440, opacity: 0.55), right]
            }
            return [Glow(color: Palette.violet, x: 0.14, y: 0.75, size: 500, opacity: 0.45),
                    Glow(color: Palette.pink, x: 0.34, y: 0.92, size: 380, opacity: 0.25), right]
        case .ai:
            return [Glow(color: Palette.claude, x: 0.22, y: 0.55, size: 600, opacity: waiting ? 0.7 : 0.45),
                    Glow(color: Palette.violet, x: 0.86, y: 0.75, size: 420, opacity: 0.35)]
        case .clipboard: return pair(Palette.blue, Palette.violet)
        case .shelf: return pair(Palette.cyan, Palette.blue)
        case .calendar: return pair(Palette.orange, Palette.red)
        case .timer: return pair(timer.phase.color, Palette.violet, 0.5)
        case .cuely: return pair(Palette.violet, Palette.pink)
        case .notes: return pair(Palette.yellow, Palette.orange, 0.32)
        case .mirror: return pair(Palette.cyan, Palette.violet, 0.28)
        }
    }

    private func pair(_ a: Color, _ b: Color, _ opacity: Double = 0.42) -> [Glow] {
        [Glow(color: a, x: 0.18, y: 0.82, size: 520, opacity: opacity),
         Glow(color: b, x: 0.78, y: 0.88, size: 460, opacity: opacity * 0.75)]
    }

    /// A quiet, deep wash rising from below the island; the top under the camera stays black.
    /// Colours are muted and the spots sit past the bottom edge, so only their soft tails show.
    func glows(for island: Island) -> [Glow] {
        let c = island.colors.map { $0.muted() }
        return [Glow(color: c[0], x: 0.22, y: 1.22, size: 620, opacity: 0.55),
                Glow(color: c[1], x: 0.8, y: 1.28, size: 520, opacity: 0.32)]
    }
}

extension Island {
    /// Background pair for this island; app notifications take the colours of the app's icon.
    var colors: [Color] {
        switch kind {
        case .agentDone(let provider, _, _, _, _, _):
            return provider == "codex" ? [Palette.blue, Palette.cyan] : [Palette.claude, Palette.orange]
        case .notification(let bundleID, _, _, _): return IconColors.of(bundleID) ?? [Palette.violet, Palette.pink]
        case .call: return [Palette.green, Palette.mint]
        case .airpods: return [Palette.cyan, Palette.blue]
        case .download: return [Palette.blue, Palette.cyan]
        case .timerDone: return [Palette.orange, Palette.pink]
        case .event: return [Palette.red, Palette.orange]
        case .command(_, _, let exit, _, _): return exit == 0 ? [Palette.green, Palette.mint] : [Palette.red, Palette.coral]
        }
    }
}

/// Glow colours of app icons, computed once per app.
enum IconColors {
    private static var cache: [String: [Color]] = [:]

    static func of(_ bundleID: String) -> [Color]? {
        if let hit = cache[bundleID] { return hit.isEmpty ? nil : hit }
        let colors = NotificationWatcher.icon(for: bundleID)?.glowColors() ?? []
        cache[bundleID] = colors
        return colors.isEmpty ? nil : colors
    }
}

extension FocusTimer.Phase {
    var colors: [Color] {
        switch self {
        case .focus: return [Palette.coral, Palette.orange]
        case .shortBreak, .longBreak: return [Palette.green, Palette.mint]
        case .plain: return [Palette.orange, Palette.pink]
        }
    }
    var color: Color { colors[0] }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
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
        insertion: .modifier(active: Materialize(amount: 1), identity: Materialize(amount: 0))
            .animation(.easeOut(duration: 0.3).delay(0.07).speed(Motion.speed)),
        removal: .opacity.animation(.easeIn(duration: 0.1).speed(Motion.speed)))

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
                .background(alignment: .top) { underglow }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                model.dropFiles(providers)
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .environment(\.motionPaused, model.resting)
        .animation(spring, value: mode)
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: model.hasLiveActivity)
    }

    /// While music plays, the collapsed notch casts a little of the cover's colour below itself.
    @ViewBuilder private var underglow: some View {
        if mode == .collapsed && model.flash == nil && model.live == .music {
            Ellipse()
                .fill(EllipticalGradient(colors: [model.nowPlaying.glowColors[0].opacity(0.5), .clear], center: .center))
                .frame(width: size.width * 0.9, height: 34)
                .offset(y: model.notch.height - 15)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .expanded:
            ZStack(alignment: .top) {
                AmbientGlow(glows: model.ambient, blackTop: model.notch.height)
                ExpandedView(model: model)
                    .padding(.horizontal, NotchModel.ear + 18)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
            }
            .frame(width: NotchModel.expandedSize.width + 2 * NotchModel.ear, height: NotchModel.expandedSize.height)
            .transition(Self.contentTransition)
        case .prompter:
            PrompterView(cuely: model.cuely, notch: model.notch)
                .padding(.horizontal, NotchModel.ear + 14)
                .frame(width: NotchModel.prompterSize.width, height: NotchModel.prompterSize.height)
                .transition(Self.contentTransition)
        case .island:
            if let island = model.island {
                ZStack(alignment: .top) {
                    AmbientGlow(glows: model.glows(for: island), blackTop: model.notch.height)
                    IslandView(model: model, island: island)
                        .padding(.horizontal, NotchModel.ear + 14)
                        .padding(.top, model.notch.height + 4)
                        .padding(.bottom, 12)
                }
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
            slot(leftSlot)
            Spacer(minLength: model.notch.width)
            slot(rightSlot)
        }
        .frame(height: model.notch.height)
        .clipped()
        .animation(Motion.smooth, value: slotKey)
    }

    /// Changes whenever the slots show something else, so the old content scales away and the new one in.
    private var slotKey: String { "\(model.flash?.kind ?? "")|\(String(describing: model.live))" }

    private func slot(_ content: some View) -> some View {
        ZStack {
            content
                .id(slotKey)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .frame(width: model.slotWidth)
    }

    @ViewBuilder private var leftSlot: some View {
        switch model.flash {
        case .charging:
            Image(systemName: "bolt.fill").foregroundStyle(Palette.green)
        case .screenshot(let url):
            // The shelf's thumbnail, not the full screenshot read from disk on every redraw.
            if let image = model.shelf.thumbnails[url.path] {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 24, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "photo").foregroundStyle(muted)
            }
        case .copied:
            Image(systemName: "doc.on.clipboard.fill")
        case .noText:
            Image(systemName: "text.viewfinder").foregroundStyle(muted)
        case .volume(let level, let muted):
            HStack(spacing: 6) {
                Image(systemName: VolumeBar.symbol(level, muted: muted)).font(.system(size: 12, weight: .medium))
                    .frame(width: 18, alignment: .leading)
                Text("Звук").font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
        case .focus(let on, let name, let symbol):
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on ? Palette.violet.lifted() : .white.opacity(0.6))
                    .frame(width: 18, alignment: .leading)
                Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
        case .brightness(let level):
            HStack(spacing: 6) {
                Image(systemName: level < 0.5 ? "sun.min.fill" : "sun.max.fill").font(.system(size: 12, weight: .medium))
                    .frame(width: 18, alignment: .leading)
                Text("Яркость").font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
        case nil:
            switch model.live {
            case .permission: Image(systemName: "sparkles").foregroundStyle(Palette.claude.opacity(0.85))
            case .timer: Image(systemName: "timer").foregroundStyle(model.timer.phase.color)
            case .download: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Palette.blue)
            case .agents:
                // Music keeps its cover on the left while an agent works on the right.
                if model.nowPlaying.isPlaying {
                    Artwork(image: model.nowPlaying.artwork, size: 22, radius: 6)
                } else {
                    Image(systemName: "sparkles").foregroundStyle(Palette.claude.opacity(0.85))
                }
            case .music: Artwork(image: model.nowPlaying.artwork, size: 22, radius: 6)
            case .prompter, nil: EmptyView()
            }
        }
    }

    @ViewBuilder private var rightSlot: some View {
        switch model.flash {
        case .charging(let percent):
            Text("\(percent)%").font(.rounded(12)).foregroundStyle(Palette.green)
        case .screenshot:
            Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(muted)
        case .copied:
            Image(systemName: "checkmark").foregroundStyle(Palette.green)
        case .noText:
            Image(systemName: "xmark").foregroundStyle(muted)
        case .volume(let level, let muted):
            VolumeBar(level: muted ? 0 : CGFloat(level))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
        case .focus(let on, _, _):
            Text(on ? "Вкл" : "Выкл").font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? Palette.violet.lifted() : .white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
        case .brightness(let level):
            VolumeBar(level: CGFloat(level))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
        case nil:
            switch model.live {
            case .permission: Circle().fill(Palette.orange.opacity(0.9)).frame(width: 6, height: 6)
            case .timer:
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let remaining = model.timer.remaining(at: context.date)
                    Text(FocusTimer.format(remaining))
                        .font(.rounded(12)).monospacedDigit()
                        .foregroundStyle(model.timer.isPaused ? muted : model.timer.phase.color)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(Motion.quick, value: Int(remaining))
                }
            case .download: DownloadRing(fraction: model.downloads.active?.fraction)
            case .agents: Spinner()
            case .music: Bars(color: model.nowPlaying.glowColors[0])
            case .prompter, nil: EmptyView()
            }
        }
    }
}

/// The level bar of the volume flash.
struct VolumeBar: View {
    let level: CGFloat

    var body: some View {
        Capsule().fill(Color.white.opacity(0.22))
            .frame(width: 72, height: 5)
            .overlay(alignment: .leading) {
                Capsule().fill(Color.white).frame(width: max(level > 0 ? 5 : 0, 72 * level))
            }
            .animation(.easeOut(duration: 0.12), value: level)
    }

    static func symbol(_ level: Float, muted: Bool) -> String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        return level < 0.34 ? "speaker.wave.1.fill" : (level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }
}

struct DownloadRing: View {
    var fraction: Double?
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
            if let fraction {
                Circle().trim(from: 0, to: fraction)
                    .stroke(LinearGradient(colors: [Palette.cyan, Palette.blue], startPoint: .top, endPoint: .bottom),
                            style: .init(lineWidth: 2.5, lineCap: .round))
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
            leading.frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) { text }
            Spacer(minLength: 4)
            trailing
            Button { model.dismissIsland() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(muted)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.icon)
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
        case .agentDone:
            Badge(symbol: "checkmark", colors: island.colors, soft: true)
        case .notification(let bundleID, _, _, _):
            if let icon = NotificationWatcher.icon(for: bundleID) {
                Image(nsImage: icon).resizable().shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            } else {
                Badge(symbol: "bell.fill", colors: [Palette.violet, Palette.pink], soft: true)
            }
        case .call:
            if let callImage {
                Image(nsImage: callImage).resizable().scaledToFill().clipShape(Circle())
                    .overlay(Circle().strokeBorder(Palette.green, lineWidth: 2))
            } else {
                Badge(symbol: "phone.fill", colors: [Palette.green, Palette.mint], soft: true)
            }
        case .airpods(let name, _):
            Image(systemName: name.lowercased().contains("max") ? "airpodsmax" : (name.lowercased().contains("airpods") ? "airpodspro" : "headphones"))
                .font(.system(size: 26))
        case .download:
            Badge(symbol: "arrow.down", colors: [Palette.blue, Palette.cyan], soft: true)
        case .timerDone:
            Badge(symbol: "timer", colors: [Palette.orange, Palette.pink], soft: true)
        case .event:
            Badge(symbol: "calendar", colors: [Palette.red, Palette.orange], soft: true)
        case .command(_, _, let exit, _, _):
            Badge(symbol: exit == 0 ? "terminal.fill" : "exclamationmark.triangle.fill", colors: island.colors, soft: true)
        }
    }

    @ViewBuilder private var text: some View {
        switch island.kind {
        case .agentDone(let provider, let project, let message, let duration, _, _):
            HStack(spacing: 6) {
                Text("\(project) — готово").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text([provider == "codex" ? "Codex" : "Claude", duration.map { "за " + Format.span($0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(faint).lineLimit(1)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
            }
        case .notification(_, let app, let title, let body):
            Text(app).font(.system(size: 10.5, weight: .medium)).foregroundStyle(faint)
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if !body.isEmpty { Text(body).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(2) }
        case .call(let name, let bundleID):
            Text(name.isEmpty ? "Входящий звонок" : name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text("Звонок · \(NotificationWatcher.appName(for: bundleID))").font(.system(size: 11)).foregroundStyle(muted)
        case .airpods(let name, let levels):
            Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            if levels.isEmpty {
                Text("Подключены").font(.system(size: 11)).foregroundStyle(muted)
            } else {
                HStack(spacing: 10) {
                    ForEach(levels.sorted(by: { $0.key < $1.key }), id: \.key) { label, value in
                        HStack(spacing: 4) {
                            Text(label).foregroundStyle(muted)
                            Text("\(value)%").foregroundStyle(value <= 20 ? Palette.red : Palette.green)
                        }
                        .font(.rounded(11.5, .medium)).monospacedDigit()
                    }
                }
            }
        case .download(let name, _):
            Text("Загружено").font(.system(size: 10.5, weight: .medium)).foregroundStyle(faint)
            Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        case .timerDone(let title, let subtitle):
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(muted)
        case .command(let text, let seconds, let exit, _, _):
            Text(exit == 0 ? "Команда завершилась" : "Команда с ошибкой · код \(exit)")
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(exit == 0 ? faint : Palette.salmon)
            Text(text).font(.system(size: 13, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Text("шла " + Format.until(seconds)).font(.system(size: 11)).foregroundStyle(muted)
        case .event(let title, let start, _):
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text("Начало в \(start.formatted(date: .omitted, time: .shortened)) · \(start.formatted(.relative(presentation: .named)))")
                .font(.system(size: 11)).foregroundStyle(muted)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch island.kind {
        case .agentDone(_, _, _, _, let pid, let terminal):
            Button("Открыть") { AgentHub.focus(pid: pid, terminal: terminal); model.dismissIsland() }
                .buttonStyle(.pill(small: true))
        case .download(_, let path):
            HStack(spacing: 6) {
                if Downloads.isRunnable(path) {
                    Button("В Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]); model.dismissIsland() }
                        .buttonStyle(.pill(small: true))
                        .help("Программы и скрипты из интернета Nook не открывает сам — проверьте файл в Finder")
                } else {
                    Button("Открыть") { NSWorkspace.shared.open(URL(fileURLWithPath: path)); model.dismissIsland() }
                        .buttonStyle(.pill(small: true))
                }
                Button("На полку") { model.shelf.add([URL(fileURLWithPath: path)]); model.dismissIsland() }
                    .buttonStyle(.pill(small: true))
            }
        case .timerDone:
            HStack(spacing: 6) {
                Button("+5 мин") { model.timer.start(minutes: 5); model.dismissIsland() }.buttonStyle(.pill(.primary, small: true))
                if model.timer.pomodoro {
                    Button("Стоп") { model.timer.reset(); model.dismissIsland() }.buttonStyle(.pill(small: true))
                }
            }
        case .event(_, _, let url):
            if let url {
                Button("Подключиться") { NSWorkspace.shared.open(url); model.dismissIsland() }
                    .buttonStyle(.pill(.tint(Palette.green), small: true))
            }
        case .command(_, _, _, let pid, let terminal):
            Button("Открыть") { AgentHub.focus(pid: pid, terminal: terminal); model.dismissIsland() }
                .buttonStyle(.pill(small: true))
        case .call(_, let bundleID):
            Button("Открыть") { NotificationWatcher.open(bundleID: bundleID); model.dismissIsland() }
                .buttonStyle(.pill(.tint(Palette.green), small: true))
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
        case .agentDone(_, _, _, _, let pid, let terminal): AgentHub.focus(pid: pid, terminal: terminal)
        case .notification(let bundleID, _, _, _), .call(_, let bundleID): NotificationWatcher.open(bundleID: bundleID)
        case .download(_, let path): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .event: model.calendar.openCalendar()
        case .command(_, _, _, let pid, let terminal): AgentHub.focus(pid: pid, terminal: terminal)
        case .airpods, .timerDone: break
        }
        model.dismissIsland()
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
                ListScroll {
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
                    Text("\(Int(cuely.wordsPerMinute)) сл/мин").font(.rounded(10, .medium)).monospacedDigit().foregroundStyle(muted)
                    small("hare.fill") { cuely.changeSpeed(10) }
                } else {
                    Label(cuely.status ?? "Голос", systemImage: "waveform").font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                }
                small("backward.end.fill") { cuely.restart() }
                small("xmark") { cuely.stop() }
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .opacity(hover || cuely.isPaused ? 1 : 0.3)
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
        Button(action: action) { Image(systemName: icon).font(.system(size: 11)).frame(width: 20, height: 18) }
            .buttonStyle(.icon)
    }
}

// MARK: Expanded

struct ExpandedView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var agents: AgentHub
    @ObservedObject var battery: Battery
    @ObservedObject var weather: Weather
    @ObservedObject var caffeine: Caffeine
    @Namespace private var tabSpace

    init(model: NotchModel) {
        self.model = model
        agents = model.agents
        battery = model.battery
        weather = model.weather
        caffeine = model.caffeine
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            ZStack(alignment: .top) {
                Group {
                    switch model.tab {
                    case .home: HomeTab(model: model)
                    case .clipboard: ClipboardTab(model: model, store: model.clipboard)
                    case .shelf: ShelfTab(model: model, shelf: model.shelf)
                    case .ai: AgentsTab(agents: model.agents, limits: model.limits)
                    case .calendar: CalendarTab(store: model.calendar)
                    case .timer: TimerTab(timer: model.timer)
                    case .cuely: CuelyTab(model: model, cuely: model.cuely)
                    case .notes: NotesTab(model: model, notes: model.notes)
                    case .mirror: MirrorTab(camera: model.mirror)
                    }
                }
                .id(model.tab)
                // The old tab leaves quickly, so two tabs never show through each other for long.
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.04).speed(Motion.speed)),
                    removal: .opacity.animation(.easeIn(duration: 0.08).speed(Motion.speed))))
            }
            // A fixed height: a tab taller than its room is cut at the bottom instead of pushing the header
            // up under the camera (the room depends on the notch height: 32 pt here, 38 pt on newer Macs).
            .frame(maxWidth: .infinity)
            .frame(height: contentHeight, alignment: .top)
            .clipped()
        }
        .overlay(alignment: .topTrailing) {
            if model.showPower {
                ZStack(alignment: .topTrailing) {
                    // A click anywhere else closes the card.
                    Color.black.opacity(0.001)
                        .onTapGesture { withAnimation(Motion.smooth) { model.showPower = false } }
                    PowerCard(battery: battery)
                        .frame(width: 300)
                        .padding(.top, max(model.notch.height - 6, 24) + 6)
                        .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .onChange(of: model.tab) { _, _ in model.showPower = false }
        .background {
            // Esc closes the panel whenever it has keyboard focus (opened by the hotkey or a click in a field).
            Button("") { model.collapse() }
                .keyboardShortcut(.cancelAction)
                .focusable(false)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    private var headerHeight: CGFloat { max(model.notch.height - 6, 24) }

    /// Panel height minus the top and bottom padding, the header and the gap under it.
    private var contentHeight: CGFloat { NotchModel.expandedSize.height - 6 - 16 - headerHeight - 10 }

    private var header: some View {
        HStack(spacing: 6) {
            tabGroup(Tab.leftSide)
            Spacer(minLength: model.notch.width + 8)
            tabGroup(Tab.rightSide)
            statusChip
            HeaderButton(symbol: caffeine.on ? "cup.and.saucer.fill" : "cup.and.saucer",
                         active: caffeine.on, tint: Palette.orange,
                         help: caffeine.on ? "Кофеин включён: Mac не засыпает. Нажмите, чтобы выключить"
                                           : "Кофеин: Mac не будет засыпать (например, пока работают агенты)") {
                withAnimation(Motion.quick) { caffeine.toggle() }
            }
            HeaderButton(symbol: "gearshape", help: "Настройки Nook") { model.onOpenMenu?() }
        }
        .frame(height: headerHeight)
    }

    private func tabGroup(_ tabs: [Tab]) -> some View {
        HStack(spacing: 1) {
            ForEach(tabs) { tab in
                TabPill(tab: tab, active: model.tab == tab, badge: tab == .ai && !agents.permissions.isEmpty,
                        space: tabSpace) { model.select(tab) }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)).overlay(Capsule().strokeBorder(Color.white.opacity(0.08))))
    }

    @ViewBuilder private var statusChip: some View {
        let hasWeather = weather.temperature != nil
        if hasWeather || battery.hasBattery {
            Button { withAnimation(Motion.smooth) { model.showPower.toggle() } } label: { statusLabel(hasWeather) }
                .buttonStyle(.plain)
                // Never squeezed to "…": the gap around the camera gives way first.
                .fixedSize()
                .layoutPriority(1)
                .hoverLift()
        }
    }

    private func statusLabel(_ hasWeather: Bool) -> some View {
            HStack(spacing: 6) {
                if let t = weather.temperature {
                    Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 11))
                    Text("\(Int(t.rounded()))°").font(.system(size: 12, weight: .medium))
                        .contentTransition(.numericText())
                }
                if hasWeather && battery.hasBattery {
                    Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 11)
                }
                if battery.hasBattery {
                    Image(systemName: batteryIcon).font(.system(size: 12))
                        .foregroundStyle(battery.pluggedIn ? Palette.green : (battery.percent <= 20 ? Palette.red : .white.opacity(0.8)))
                    if battery.percent <= 20 && !battery.pluggedIn {
                        Text("\(battery.percent)%").font(.rounded(11)).foregroundStyle(Palette.red)
                    } else if battery.held {
                        Image(systemName: "pause.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(Palette.green)
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(model.showPower ? 0.16 : 0.07))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08))))
            .contentShape(Capsule())
            .help([hasWeather ? "\(weather.place): \(weather.summary)" : nil,
                   battery.hasBattery ? "Батарея \(battery.percent)% · нажмите для подробностей" : nil]
                .compactMap { $0 }.joined(separator: " · "))
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

/// A round icon button at the right end of the header (coffee, settings).
struct HeaderButton: View {
    let symbol: String
    var active = false
    var tint: Color = .white
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(active ? tint.lifted() : Color.white.opacity(hover ? 1 : 0.7))
                .frame(width: 26, height: 24)
                .background(Capsule().fill(active ? tint.opacity(0.22) : Color.white.opacity(hover ? 0.12 : 0.07))
                    .overlay(Capsule().strokeBorder(active ? tint.opacity(0.35) : Color.white.opacity(0.08))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.quick, value: hover)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// One tab in the header; the active one carries the sliding pill.
struct TabPill: View {
    let tab: Tab
    let active: Bool
    let badge: Bool
    let space: Namespace.ID
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon).font(.system(size: 11, weight: .medium))
                if active {
                    Text(tab.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                }
                if badge { Circle().fill(accent).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, active ? 10 : 7).padding(.vertical, 4)
            .background {
                if active {
                    Capsule().fill(Color.white.opacity(0.18)).matchedGeometryEffect(id: "activeTab", in: space)
                } else if hover {
                    Capsule().fill(Color.white.opacity(0.07))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(tab.shortcut, modifiers: .command)
        .foregroundStyle(active || hover ? Color.white : Color.white.opacity(0.6))
        .animation(Motion.quick, value: hover)
        .onHover { hover = $0 }
        .help("\(tab.title)  ⌘\(Tab.allCases.firstIndex(of: tab).map { $0 + 1 } ?? 1)")
    }
}

// MARK: Home

struct HomeTab: View {
    @ObservedObject var model: NotchModel
    var body: some View {
        HStack(spacing: 10) {
            NowPlayingCard(np: model.nowPlaying, compact: true).frame(width: 268).entrance(0)
            AgentsSummary(agents: model.agents, limits: model.limits) { model.select(.ai) }.entrance(1)
            VStack(spacing: 10) {
                NextEventCard(store: model.calendar) { model.select(.calendar) }.entrance(2)
                WeatherCard(weather: model.weather).entrance(3)
            }
            .frame(width: 150)
        }
    }
}

struct NextEventCard: View {
    @ObservedObject var store: CalendarStore
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            Card {
                VStack(alignment: .leading, spacing: 3) {
                    if let e = store.nextEvent {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                            Text(e.start <= Date() ? "Идёт сейчас" : e.start.formatted(.relative(presentation: .named)).capitalizedFirst)
                                .lineLimit(1)
                        }
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                        Text(e.title).font(.system(size: 14, weight: .semibold)).lineLimit(e.meetingURL == nil ? 2 : 1)
                        Text(Self.subtitle(e)).font(.system(size: 11.5)).foregroundStyle(muted).lineLimit(1)
                        Spacer(minLength: 4)
                        if let url = e.meetingURL {
                            Button { NSWorkspace.shared.open(url) } label: { Label("Войти", systemImage: "video.fill") }
                                .buttonStyle(.pill(.tint(Palette.green), small: true))
                                .help("Подключиться: \(Self.meetingName(url))")
                        }
                    } else if !store.calendarAccess {
                        Caps(text: "Календарь")
                        Text("Нет доступа").font(.system(size: 14, weight: .semibold))
                        Text("Покажу встречи").font(.system(size: 11.5)).foregroundStyle(muted).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Разрешить") { store.requestAccess() }.buttonStyle(.pill(.primary, small: true))
                    } else {
                        Caps(text: "Календарь")
                        Text("Сегодня свободно").font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(store.reminders.isEmpty ? "Напоминаний нет" : Format.count(store.reminders.count, "напоминание", "напоминания", "напоминаний"))
                            .font(.system(size: 11.5)).foregroundStyle(muted)
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }

    static func subtitle(_ e: CalendarStore.Event) -> String {
        e.allDay ? "Весь день"
            : "\(e.start.formatted(date: .omitted, time: .shortened))–\(e.end.formatted(date: .omitted, time: .shortened))"
    }

    static func meetingName(_ url: URL) -> String {
        let host = url.host ?? ""
        if host.contains("zoom") { return "Zoom" }
        if host.contains("meet.google") { return "Google Meet" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        if host.contains("whereby") { return "Whereby" }
        return host
    }
}

struct WeatherCard: View {
    @ObservedObject var weather: Weather
    var body: some View {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Weather.app")) } label: { card }
            .buttonStyle(CardButtonStyle())
            .help("Открыть Погоду")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 4) {
                Text(weather.place.isEmpty ? "Погода" : weather.place)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 20))
            }
            Spacer(minLength: 0)
            Text(weather.temperature.map { "\(Int($0.rounded()))°" } ?? "—").font(.rounded(34)).lineLimit(1)
                .contentTransition(.numericText())
                .animation(Motion.smooth, value: weather.temperature)
            Text(weather.summary).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            if let h = weather.high, let l = weather.low {
                Text("↑\(Int(h.rounded()))°  ↓\(Int(l.rounded()))°").font(.rounded(11, .medium)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(tint: [Palette.blue.opacity(0.6), Palette.navy.opacity(0.35)], stroke: .white.opacity(0.12))
    }
}

// MARK: Calendar

struct CalendarTab: View {
    @ObservedObject var store: CalendarStore
    @State private var newReminder = ""

    var body: some View {
        if !store.calendarAccess && !store.remindersAccess {
            Card(tint: [Palette.orange.opacity(0.14), .clear]) {
                VStack(spacing: 10) {
                    Badge(symbol: "calendar.badge.plus", colors: [Palette.orange, Palette.red], size: 52)
                    Text("Покажу события и напоминания прямо в вырезе").font(.system(size: 15, weight: .semibold))
                    Button(store.asked ? "Открыть настройки доступа" : "Разрешить доступ") { store.requestAccess() }
                        .buttonStyle(.pill(.primary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .entrance(0)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Card { events }.frame(maxWidth: .infinity).entrance(0)
                Card { reminders }.frame(width: 280).entrance(1)
            }
            .animation(Motion.smooth, value: store.events.map(\.id))
            .animation(Motion.smooth, value: store.reminders.map(\.id))
        }
    }

    private var events: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("События").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { store.openCalendar() } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 12)) }
                    .buttonStyle(.icon).foregroundStyle(muted).help("Открыть Календарь")
            }
            if store.events.isEmpty {
                Text("Сегодня и завтра свободно").font(.system(size: 12)).foregroundStyle(muted)
            }
            ListScroll {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.events) { e in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: e.color)).frame(width: 3, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(Self.when(e)).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                            }
                            Spacer()
                            if let url = e.meetingURL {
                                Button("Подключиться") { NSWorkspace.shared.open(url) }
                                    .buttonStyle(.pill(.tint(Palette.green), small: true))
                            }
                        }
                    }
                }
            }
        }
    }

    private var reminders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Напоминания").font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                TextField("Новое напоминание", text: $newReminder)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .onSubmit { store.addReminder(newReminder); newReminder = "" }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .glass(radius: 10)
            ListScroll {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(store.reminders) { r in
                        HStack(spacing: 8) {
                            Button { store.complete(r) } label: {
                                Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(Color(nsColor: r.color))
                            }
                            .buttonStyle(.icon)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(r.title).font(.system(size: 12)).lineLimit(1)
                                if let due = r.due {
                                    Text(due.formatted(.relative(presentation: .named)))
                                        .font(.system(size: 10)).foregroundStyle(due < Date() ? Palette.red : muted)
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
        let colors = timer.phase.colors
        HStack(spacing: 10) {
            Card(tint: [colors[0].opacity(0.2), .clear], padding: 18) {
                HStack(spacing: 22) {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let remaining = timer.remaining(at: context.date)
                        let fraction = timer.total > 0 ? remaining / timer.total : 0
                        ZStack {
                            RingGauge(fraction: (timer.isRunning || timer.isPaused) ? fraction : 1, colors: colors, lineWidth: 10)
                            VStack(spacing: 2) {
                                Text(FocusTimer.format(remaining)).font(.rounded(30)).monospacedDigit()
                                    .contentTransition(.numericText(countsDown: true))
                                    .animation(Motion.quick, value: Int(remaining))
                                Text(timer.phase.title).font(.system(size: 11)).foregroundStyle(muted)
                            }
                        }
                        .frame(width: 156, height: 156)
                        .shadow(color: colors[0].opacity(0.35), radius: 14)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if timer.isRunning || timer.isPaused {
                            HStack(spacing: 8) {
                                Button(timer.isPaused ? "Продолжить" : "Пауза") { timer.pauseResume() }.buttonStyle(.pill(.primary))
                                Button("Сброс") { timer.reset() }.buttonStyle(.pill())
                            }
                            HStack(spacing: 8) {
                                Button("+1 мин") { timer.add(minutes: 1) }.buttonStyle(.pill())
                                Button("+5 мин") { timer.add(minutes: 5) }.buttonStyle(.pill())
                            }
                        } else {
                            Caps(text: "Таймер")
                            Text("Выберите время справа").font(.system(size: 15, weight: .semibold))
                            Text("или запустите Помодоро 25 / 5").font(.system(size: 12)).foregroundStyle(muted)
                        }
                        if timer.pomodoro {
                            HStack(spacing: 5) {
                                ForEach(0..<4) { i in
                                    Circle().fill(i < timer.completedFocus % 4 || (timer.completedFocus > 0 && timer.completedFocus % 4 == 0 && timer.phase == .longBreak) ? colors[0] : Color.white.opacity(0.15))
                                        .frame(width: 8, height: 8)
                                }
                                Text("помодоро: \(timer.completedFocus)").font(.system(size: 11)).foregroundStyle(muted)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .animation(Motion.smooth, value: timer.isRunning || timer.isPaused)
            }
            .entrance(0)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Caps(text: "Быстрый старт")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(presets, id: \.self) { m in
                            Button(m >= 60 ? "1 ч" : "\(Int(m)) м") { timer.pomodoro = false; timer.start(minutes: m) }
                                .buttonStyle(TileStyle())
                        }
                    }
                    Spacer(minLength: 0)
                    Button { timer.startPomodoro() } label: {
                        Label("Помодоро 25 / 5", systemImage: "flame.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pill(.gradient(FocusTimer.Phase.focus.colors)))
                }
            }
            .frame(width: 250)
            .entrance(1)
        }
    }
}

/// Square-ish glass button for grids of presets.
struct TileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { TileBody(configuration: configuration) }
}

private struct TileBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hover = false
    var body: some View {
        configuration.label
            .font(.rounded(13, .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(hover ? 0.16 : 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

// MARK: Cuely

struct CuelyTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var cuely: Cuely

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Сценарии").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { cuely.newScript() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(.icon).help("Новый сценарий")
                }
                ListScroll {
                    VStack(spacing: 2) {
                        ForEach(cuely.scripts) { s in
                            let selected = s.id == cuely.current?.id
                            Text(s.title).font(.system(size: 12)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background {
                                    if selected {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.clear)
                                            .glass(tint: [Palette.violet.opacity(0.35), Palette.pink.opacity(0.1)], radius: 9)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { cuely.currentID = s.id }
                                .contextMenu { Button("Удалить") { cuely.delete(s) } }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 160)
            .glass()
            .entrance(0)

            TextEditor(text: Binding(get: { cuely.current?.body ?? "" }, set: { cuely.update(body: $0) }))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(10)
                .glass()
                .onTapGesture { model.stayOpen() }
                .entrance(1)

            VStack(alignment: .leading, spacing: 12) {
                GlassSegmented(selection: $cuely.voiceFollow, options: [(false, "Авто"), (true, "Голос")])
                if cuely.voiceFollow {
                    Picker("Язык", selection: $cuely.language) {
                        ForEach(Cuely.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .font(.system(size: 11))
                    Text("Текст идёт за вашей речью. Распознавание на Mac, звук не сохраняется.")
                        .font(.system(size: 10)).foregroundStyle(muted)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Скорость · \(Int(cuely.wordsPerMinute)) слов/мин").font(.system(size: 11)).foregroundStyle(muted)
                        Slider(value: $cuely.wordsPerMinute, in: 60...300, step: 5).tint(Palette.violet)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Шрифт · \(Int(cuely.fontSize))").font(.system(size: 11)).foregroundStyle(muted)
                    Slider(value: $cuely.fontSize, in: 16...40, step: 1).tint(Palette.violet)
                }
                Spacer(minLength: 0)
                Button { cuely.present(); model.focusPanel() } label: {
                    Label("Начать", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.gradient([Palette.violet, Palette.pink])))
                Text("Пробел — пауза, ←/→ — скорость, Esc — стоп").font(.system(size: 10)).foregroundStyle(faint)
            }
            .frame(width: 190)
            .animation(Motion.smooth, value: cuely.voiceFollow)
            .entrance(2)
        }
    }
}

/// Two or more options in a glass capsule with a sliding selection.
struct GlassSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var space

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let active = selection == option.0
                Button { withAnimation(Motion.tab) { selection = option.0 } } label: {
                    Text(option.1).font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background {
                            if active { Capsule().fill(Color.white.opacity(0.18)).matchedGeometryEffect(id: "segment", in: space) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(active ? Color.white : muted)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.07)).overlay(Capsule().strokeBorder(Color.white.opacity(0.08))))
    }
}
