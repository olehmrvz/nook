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
    /// The closed notch changing what it shows: the shape overshoots a little, like it takes a breath.
    static var morph: Animation { .spring(response: 0.44, dampingFraction: 0.72).speed(speed) }
}

/// Slot content goes into the camera and comes out of it: toward the middle, smaller, blurred.
private struct SlotMorph: ViewModifier {
    var amount: Double
    /// +1 in the left slot (the camera is to its right), −1 in the right one.
    var toward: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: 5 * amount)
            .scaleEffect(1 - 0.55 * amount)
            .offset(x: toward * 16 * amount)
    }
}

/// One ring that leaves the microphone when recording starts.
private struct MicRipple: View {
    var color: Color
    @State private var gone = false

    var body: some View {
        Circle().stroke(color, lineWidth: 1.5)
            .frame(width: 18, height: 18)
            .scaleEffect(gone ? 2.6 : 0.6)
            .opacity(gone ? 0 : 0.9)
            .allowsHitTesting(false)
            .onAppear {
                guard !Motion.reduce else { gone = true; return }
                withAnimation(.easeOut(duration: 0.75).speed(Motion.speed)) { gone = true }
            }
    }
}

/// Content of the panel comes into focus: from a light blur to sharp.
/// No scale: a scaled ScrollView keeps the offset AppKit gives it while it is smaller (half the shrink, 3 pt
/// at 3 %), so a list longer than its room opened with its first row cut.
private struct Materialize: ViewModifier {
    var amount: Double
    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: 6 * amount)
    }
}

extension NotchModel {
    func select(_ tab: Tab) {
        withAnimation(Motion.tab) { self.tab = tab }
    }

    /// Light behind the expanded panel: one calm, cool glow under the tiles (Figma «H»); warm only while
    /// something waits for you.
    var ambient: [Glow] {
        var glows = [Glow(color: Color(hex: 0x4658A0), x: 0.5, y: 0.78, size: 760, opacity: 0.42)]
        if !agents.permissions.isEmpty && (tab == .home || tab == .ai) {
            glows.append(Glow(color: Tone.attention, x: tab == .ai ? 0.62 : 0.86, y: 0.8, size: 460, opacity: 0.16))
        }
        return glows
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
        // A flat shape wider than the camera is as tall as macOS says the notch is, and the housing's bottom edge
        // showed under it: 1 pt more covers it. The bare notch stays as it is.
        case .island:
            let frame = model.islandFrame
            return frame.height == model.notch.height ? CGSize(width: frame.width, height: frame.height + 1) : frame
        case .collapsed:
            return CGSize(width: model.collapsedWidth,
                          height: model.notch.height + (model.slotWidth > 0 ? 1 : 0) + model.dictationTextHeight)
        }
    }

    private var radius: CGFloat {
        if mode == .island, let island = model.island { return model.dropMetrics(island).radius }
        if mode == .collapsed { return model.dictationTextHeight > 0 ? 20 : 11 }
        return mode == .expanded ? 26 : 22
    }

    /// Drops leave the menu bar with softer 12 pt corners; the collapsed notch and the panel keep 8 pt.
    private var ear: CGFloat {
        if mode == .island, let island = model.island { return model.dropMetrics(island).ear }
        return NotchModel.ear
    }

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
                .clipShape(NotchShape(bottomRadius: radius, ear: ear))
                .background(alignment: .top) {
                    NotchShape(bottomRadius: radius, ear: ear)
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
        .environment(\.motionPaused, model.resting || model.hidden)
        // Asleep for a game: not drawn at all, and its loops stand still.
        .opacity(model.hidden ? 0 : 1)
        .animation(Motion.smooth, value: model.hidden)
        .animation(spring, value: mode)
        .animation(Motion.smooth, value: model.dictationTextHeight)
        .animation(Motion.smooth, value: model.islandHovered)
        .animation(Motion.morph, value: model.island?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: model.hasLiveActivity)
        // One live thing turning into another: the shape springs to its new width (no overshoot when it closes).
        .animation(model.hasLiveActivity ? Motion.morph : spring, value: model.slotWidth)
    }

    /// While music plays, the collapsed notch casts a little of the cover's colour below itself.
    @ViewBuilder private var underglow: some View {
        if mode == .collapsed && model.flash == nil && model.live == .dictation {
            // Red while the microphone is on, violet while the words are being recognized.
            let color = model.dictation.phase == .recording ? Palette.red : Palette.violet
            Ellipse()
                .fill(EllipticalGradient(colors: [color.opacity(0.45), .clear], center: .center))
                .frame(width: size.width * 0.9, height: 34)
                .offset(y: model.notch.height - 15)
                .allowsHitTesting(false)
                .transition(.opacity)
                .animation(Motion.smooth, value: model.dictation.phase)
        } else if mode == .collapsed && model.flash == nil && model.live == .music {
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
                DropView(model: model, island: island)
                    .id(island.id)
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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                slot(leftSlot, toward: 1)
                Spacer(minLength: model.notch.width)
                slot(rightSlot, toward: -1)
            }
            .frame(height: model.notch.height)
            .clipped()
            .animation(Motion.morph, value: slotKey)
            if model.dictationTextHeight > 0 {
                // The newest words stay in view: the start of a long text gives way to "…".
                Text(model.dictation.liveText)
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.92))
                    .lineLimit(2).truncationMode(.head).lineSpacing(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, Spacing.under).padding(.horizontal, Spacing.edge - NotchModel.ear).padding(.bottom, 8)
                    .frame(height: model.dictationTextHeight)
                    .transition(.opacity)
            }
        }
    }

    /// Changes whenever the slots show something else, so the old content scales away and the new one in.
    private var slotKey: String { "\(model.flash?.kind ?? "")|\(String(describing: model.live))" }

    private func slot(_ content: some View, toward: CGFloat) -> some View {
        ZStack {
            content
                .id(slotKey)
                .transition(Self.morph(toward: toward))
        }
        .frame(width: model.slotWidth)
    }

    /// The old content leaves first; the new one comes out of the camera while the shape widens.
    private static func morph(toward: CGFloat) -> AnyTransition {
        guard !Motion.reduce else { return .opacity }
        let move = AnyTransition.modifier(active: SlotMorph(amount: 1, toward: toward), identity: SlotMorph(amount: 0, toward: toward))
        return .asymmetric(insertion: move.animation(Motion.morph.delay(0.08)),
                           removal: move.animation(.easeIn(duration: 0.16).speed(Motion.speed)))
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
            case .ai:
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.violet.lifted())
                    Text("AI").font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
            case .dictation:
                let recording = model.dictation.phase == .recording
                HStack(spacing: 6) {
                    Image(systemName: recording ? "mic.fill" : "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(recording ? Palette.red : Palette.violet.lifted())
                        .symbolEffect(.pulse, isActive: recording && !Motion.reduce)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 16)
                        .background { if recording { MicRipple(color: Palette.red) } }
                    Text(recording ? L("Запись") : L("Распознаю")).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        .contentTransition(.interpolate)
                }
                .animation(Motion.quick, value: recording)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 10)
            case .keyLock: Image(systemName: "keyboard").foregroundStyle(Palette.orange)
            case .permission: AgentCursor(projects: model.agents.permissions.prefix(1).map(\.project), blinking: false)
            case .timer: Image(systemName: "timer").foregroundStyle(model.timer.phase.color)
            case .download: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Palette.blue)
            case .agents:
                // Music keeps its cover on the left while an agent works on the right.
                if model.nowPlaying.isPlaying {
                    Artwork(image: model.nowPlaying.artwork, size: 22, radius: 6)
                } else {
                    AgentCursor(projects: model.agents.workingProjects)
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
            Text(on ? L("Вкл") : L("Выкл")).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(on ? Palette.violet.lifted() : .white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
        case .brightness(let level):
            VolumeBar(level: CGFloat(level))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
        case nil:
            switch model.live {
            case .ai: Spinner(color: Palette.violet.lifted())
            case .dictation:
                HStack(spacing: 8) {
                    if model.dictation.phase == .recording, let started = model.dictation.startedAt {
                        LevelMeter(dictation: model.dictation, color: NSColor(Palette.red.lifted())).frame(width: 34, height: 16)
                        // Once a second, and only while recording.
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(FocusTimer.format(max(0, context.date.timeIntervalSince(started))))
                                .font(.rounded(12)).monospacedDigit().foregroundStyle(.white.opacity(0.85))
                        }
                    } else {
                        Spinner(color: Palette.violet.lifted())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
            case .keyLock: LockCountdown(lock: model.keyboardLock).font(.rounded(12)).foregroundStyle(Palette.orange)
            case .permission: Circle().fill(Palette.orange.opacity(0.9)).frame(width: 6, height: 6)
            case .timer:
                // Paused, or the screens asleep: nothing changes, so no redraw twice a second.
                if model.timer.isPaused || model.resting {
                    Text(FocusTimer.format(model.timer.remaining()))
                        .font(.rounded(12)).monospacedDigit()
                        .foregroundStyle(model.timer.isPaused ? muted : model.timer.phase.color)
                } else {
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let remaining = model.timer.remaining(at: context.date)
                        Text(FocusTimer.format(remaining))
                            .font(.rounded(12)).monospacedDigit()
                            .foregroundStyle(model.timer.phase.color)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(Motion.quick, value: Int(remaining))
                    }
                }
            case .download: DownloadRing(fraction: model.downloads.active?.fraction)
            case .agents: Spinner()
            case .music: Bars(color: model.nowPlaying.glowColors[0])
            case .prompter, nil: EmptyView()
            }
        }
    }
}

/// Header button in place of the old prompter tab: locks the keyboard for 30 s to clean it.
struct KeyLockPill: View {
    @ObservedObject var lock: KeyboardLock
    @State private var hover = false
    @State private var denied = false

    var body: some View {
        Button {
            denied = !lock.lock()
        } label: {
            Image(systemName: "keyboard").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(lock.isLocked ? Tone.attention : (hover ? Color.white : Color.white.opacity(0.7)))
                .frame(width: 22, height: 22)
                .background { if hover { Circle().fill(Color.white.opacity(0.1)) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Motion.quick, value: hover)
        .onHover { hover = $0 }
        .help(denied ? L("Нужен Универсальный доступ: разрешите Nook в Настройках и нажмите ещё раз")
                     : L("Заблокировать клавиатуру на 30 секунд, чтобы её протереть"))
    }
}

/// Over the panel while the keyboard is locked: countdown and a way out with the trackpad.
struct KeyLockCard: View {
    @ObservedObject var lock: KeyboardLock

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.82))
            VStack(spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 34, weight: .light)).foregroundStyle(Palette.orange)
                Text("Клавиатура заблокирована").font(.system(size: 17, weight: .semibold))
                Text("Можно протирать. Трекпад работает.").font(.system(size: 12.5)).foregroundStyle(muted)
                LockCountdown(lock: lock).font(.system(size: 30, weight: .semibold, design: .rounded))
                Button("Разблокировать") { lock.unlock() }.buttonStyle(.pill(.primary))
            }
        }
        .padding(.top, 34)
    }
}

/// Seconds left of the keyboard lock, ticking once a second (only while locked).
struct LockCountdown: View {
    @ObservedObject var lock: KeyboardLock
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(ceil((lock.until ?? context.date).timeIntervalSince(context.date))))
            Text("0:\(String(format: "%02d", left))").monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(Motion.quick, value: left)
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

/// Ends a process from its island. The first click arms the button, the second one ends the process.
struct KillButton: View {
    let hog: ProcessWatch.Hog
    let done: () -> Void
    @State private var armed = false
    @State private var armedAt = Date.distantPast

    var body: some View {
        Button(armed ? L("Точно?") : L("Завершить")) {
            if armed {
                // The second click of a double-click is not a confirmation.
                guard Date().timeIntervalSince(armedAt) > 0.5 else { return }
                ProcessWatch.terminate(hog)
                done()
            } else {
                armedAt = Date()
                withAnimation(Motion.quick) { armed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation(Motion.quick) { armed = false } }
            }
        }
        .buttonStyle(.pill(armed ? .tint(Palette.red) : .glass, small: true))
        .help("Завершить «\(hog.name)» (PID \(hog.pid)): сначала мягко, через 3 с принудительно")
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
                    Label(cuely.status ?? L("Голос"), systemImage: "waveform").font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
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
                    case .ai: AgentsTab(model: model, agents: model.agents, limits: model.limits, usage: model.usage)
                    case .calendar: CalendarTab(store: model.calendar)
                    case .timer: TimerTab(model: model, timer: model.timer, calendar: model.calendar)
                    case .launcher: LauncherTab(model: model, launcher: model.launcher, assistant: model.assistant)
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
        .overlay {
            if model.keyboardLock.isLocked { KeyLockCard(lock: model.keyboardLock).transition(.opacity) }
        }
        .animation(Motion.smooth, value: model.keyboardLock.isLocked)
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
            // Esc closes the panel whenever it has keyboard focus (opened by the hotkey or a click in a field); the
            // clipboard opened from the search goes back there. This runs before a field's own Esc handling.
            Button("") { model.escapeKey() }
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
        // Two equal halves around the camera: nothing on the right can slide under the notch, whatever tab is open.
        // Settings → Панель switches tabs and buttons off; the groups close up around what is left.
        let left = Tab.leftSide.filter(\.isShown)
        let right = Tab.rightSide.filter(\.isShown)
        return HStack(spacing: 0) {
            HStack(spacing: 2) {
                tabs(left)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: model.notch.width + 12)
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                tabs(right)
                if !right.isEmpty { Color.clear.frame(width: 6) }
                capsule
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: headerHeight)
    }

    /// Icon tabs; the open one sits in a white circle that slides from tab to tab.
    private func tabs(_ list: [Tab]) -> some View {
        ForEach(list) { tab in
            TabPill(tab: tab, active: model.tab == tab, badge: tab == .ai && !agents.permissions.isEmpty, space: tabSpace) {
                model.select(tab)
            }
        }
    }

    /// Quick actions and status in one capsule: search, keyboard lock, coffee, settings | weather | battery.
    private var capsule: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                if HeaderItem.search.isShown {
                    HeaderButton(symbol: "magnifyingglass", active: model.tab == .launcher,
                                 help: L("Поиск программ и команд (\(Settings.launcherShortcut.title))")) {
                        model.toggleLauncherFromHotkey()
                    }
                }
                if HeaderItem.keyLock.isShown { KeyLockPill(lock: model.keyboardLock) }
                if HeaderItem.coffee.isShown {
                    HeaderButton(symbol: caffeine.on ? "cup.and.saucer.fill" : "cup.and.saucer", active: caffeine.on,
                                 help: caffeine.on ? L("Кофеин включён: Mac не засыпает. Нажмите, чтобы выключить")
                                                   : L("Кофеин: Mac не будет засыпать (например, пока работают агенты)")) {
                        withAnimation(Motion.quick) { caffeine.toggle() }
                    }
                }
                HeaderButton(symbol: "gearshape", help: L("Настройки Nook")) { model.onOpenSettings?(nil) }
            }
            statusChip
        }
        .padding(.leading, 4).padding(.trailing, hasStatus ? 10 : 4)
        .frame(height: 28)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private var hasWeather: Bool { weather.temperature != nil && HeaderItem.weather.isShown }
    private var hasBattery: Bool { battery.hasBattery && HeaderItem.battery.isShown }
    private var hasStatus: Bool { hasWeather || hasBattery }

    @ViewBuilder private var statusChip: some View {
        if hasStatus {
            Button { withAnimation(Motion.smooth) { model.showPower.toggle() } } label: { statusLabel }
                .buttonStyle(.plain)
                // Never squeezed to "…": the gap around the camera gives way first.
                .fixedSize()
                .layoutPriority(1)
                .hoverLift()
        }
    }

    private var separator: some View { Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1, height: 12) }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            if hasWeather, let t = weather.temperature {
                separator
                Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 12))
                Text("\(Int(t.rounded()))°").contentTransition(.numericText())
            }
            if hasBattery {
                separator
                Image(systemName: batteryIcon).font(.system(size: 14))
                    .foregroundStyle(battery.pluggedIn ? Tone.done : (battery.percent <= 20 ? Tone.deny : .white))
                if battery.held {
                    Image(systemName: "pause.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(Tone.done)
                }
                Text("\(battery.percent) %").foregroundStyle(battery.percent <= 20 && !battery.pluggedIn ? Tone.deny : .white)
                    .contentTransition(.numericText())
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .opacity(model.showPower ? 0.7 : 1)
        .contentShape(Rectangle())
        .help([hasWeather ? "\(weather.place): \(weather.summary)" : nil,
               battery.hasBattery ? L("Батарея \(battery.percent)% · нажмите для подробностей") : nil]
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

/// A round icon button in the header capsule (search, coffee, settings); the active one is white.
struct HeaderButton: View {
    let symbol: String
    var active = false
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? Color.black : Color.white.opacity(hover ? 1 : 0.7))
                .frame(width: 22, height: 22)
                .background {
                    if active { Circle().fill(Color.white.opacity(0.92)) } else if hover { Circle().fill(Color.white.opacity(0.1)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(Motion.quick, value: hover)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// One tab in the header: an icon; the open tab sits in a white circle that slides between tabs.
struct TabPill: View {
    let tab: Tab
    let active: Bool
    let badge: Bool
    let space: Namespace.ID
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: select) {
            Image(systemName: tab.icon)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(active ? Color.black : Color.white.opacity(hover ? 1 : 0.58))
                .frame(width: active ? 32 : 30, height: 28)
                .background {
                    if active {
                        Capsule().fill(Color.white.opacity(0.92)).matchedGeometryEffect(id: "activeTab", in: space)
                    } else if hover {
                        Capsule().fill(Color.white.opacity(0.08))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // A request waits in this tab: a still yellow dot (yellow = "ждёт тебя").
                    if badge { Circle().fill(Tone.attention).frame(width: 6, height: 6).offset(x: -5, y: 5) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(tab.shortcut, modifiers: .command)
        .animation(Motion.quick, value: hover)
        .onHover { hover = $0 }
        .help("\(tab.title)  ⌘\(Tab.allCases.firstIndex(of: tab).map { $0 + 1 } ?? 1)")
    }
}

// MARK: Home

/// The service behind a meeting link: "Zoom", "Google Meet".
enum Meeting {
    static func name(_ url: URL) -> String {
        let host = url.host ?? ""
        if host.contains("zoom") { return "Zoom" }
        if host.contains("meet.google") { return "Google Meet" }
        if host.contains("teams") { return "Teams" }
        if host.contains("webex") { return "Webex" }
        if host.contains("whereby") { return "Whereby" }
        return host
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
                GlassSegmented(selection: $cuely.voiceFollow, options: [(false, L("Авто")), (true, L("Голос"))])
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
