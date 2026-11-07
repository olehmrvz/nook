import AppKit
import SwiftUI

// MARK: Drops (Figma round 9 «Капля, докрученная»)
//
// Every island is the notch itself, grown: a flash only widens beside the camera, news drops 62 pt, a question
// drops as far as its answer needs. The band beside the camera carries who / when on the left and the state on
// the right; the body has an icon with a halo in the colour of meaning, the gist and one action.

extension Island {
    enum Size { case flash, news, ask }

    /// Trivia stays a flash until the pointer comes; questions and an overloaded Mac are big drops.
    func size(hovered: Bool) -> Size {
        switch kind {
        case .airpods, .download: return hovered ? .news : .flash
        case .notice(_, _, _, let ok) where ok: return hovered ? .news : .flash
        case .request, .hog: return .ask
        default: return .news
        }
    }

    /// The halo's colour: what the event means.
    var tone: Color {
        switch kind {
        case .agentDone, .agentsDone, .call: return Tone.done
        case .notification(let bundleID, _, _, _): return IconColors.of(bundleID)?.first ?? Tone.info
        case .airpods: return Tone.ink
        case .airpodsAway: return Tone.attention
        case .download: return Tone.info
        case .timerDone: return Tone.focus
        case .event: return Tone.meeting
        case .command(_, _, let exit, _, _): return exit == 0 ? Tone.done : Tone.deny
        case .limit(_, let left, _): return left <= 5 ? Tone.deny : Tone.attention
        case .hog: return Tone.deny
        case .dictation: return Tone.meeting
        case .notice(_, _, _, let ok): return ok ? Tone.done : Tone.deny
        case .request: return Tone.attention
        }
    }
}

extension NotchModel {
    /// Concave corners where a drop leaves the menu bar (the panel keeps 8 pt).
    static let dropEar: CGFloat = 12

    /// Width of the body (ears not included) and height under the camera band for the island on screen.
    func dropMetrics(_ island: Island) -> (width: CGFloat, body: CGFloat, radius: CGFloat, ear: CGFloat) {
        let size = island.size(hovered: islandHovered)
        if size == .flash {
            let slot: CGFloat = switch island.kind { case .download: 126; case .notice: 136; default: 120 }
            return (notch.width + 2 * slot, 0, 11, Self.ear)
        }
        let open = Spacing.under + Spacing.bottom
        switch island.kind {
        case .agentDone(let turn):
            return (480, open + 40 + (islandHovered ? DropView.moreHeight(turn) : 0), 26, Self.dropEar)
        case .agentsDone(let turns):
            let n = CGFloat(turns.count)
            return (480, open + 34 * n + (n - 1) * (2 * Spacing.gap + 1), 26, Self.dropEar)
        case .request(let id):
            return (540, open + requestBody(agents.permissions.first { $0.id == id }), 30, Self.dropEar)
        case .hog:
            return (540, open + 26 + Spacing.gap + 34 + Spacing.gap + 28, 30, Self.dropEar)
        case .call, .timerDone:
            return (480, open + 40, 26, Self.dropEar)
        default:
            return (460, open + 40, 26, Self.dropEar)
        }
    }

    /// The window frame of the island: the body plus both ears, the band plus the body.
    var islandFrame: CGSize {
        guard let island else { return .zero }
        let m = dropMetrics(island)
        return CGSize(width: m.width + 2 * m.ear, height: notch.height + m.body)
    }

    /// Blocks of a request drop, without the padding above and below.
    func requestBody(_ request: AgentHub.Permission?) -> CGFloat {
        guard let request else { return 40 }
        switch request.tool {
        case "AskUserQuestion": return 36 + Spacing.gap + 30
        case "ExitPlanMode": return 26 + Spacing.gap + 60 + Spacing.gap + 28
        default:
            let command: CGFloat = DropRequest.lineCount(request.summary) > 1 ? 50 : 34
            return 26 + Spacing.gap + command + Spacing.gap + 28 + (request.suggestions != nil ? Spacing.list + 13 : 0)
        }
    }
}

struct DropView: View {
    /// How much an agent's drop grows on hover: the rest of its message (up to three lines in the ~255 pt
    /// column beside the button) and the facts row. Nothing more to show, no growth.
    static func moreHeight(_ turn: AgentTurn) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5)
        let line = NSLayoutManager().defaultLineHeight(for: font)
        let text = turn.message.isEmpty ? L("ход завершён") : turn.message
        let height = (text as NSString).boundingRect(with: CGSize(width: 255, height: CGFloat.greatestFiniteMagnitude),
                                                      options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        let lines = min(3, max(1, Int((height / line - 0.05).rounded(.up))))
        let needed = 18 + 3 + CGFloat(lines) * line + (turn.summary.isEmpty ? 0 : 4 + 14)
        return max(0, (needed - 40).rounded(.up))
    }

    @ObservedObject var model: NotchModel
    @ObservedObject var agents: AgentHub
    let island: Island
    @State private var callImage: NSImage?

    init(model: NotchModel, island: Island) {
        self.model = model
        agents = model.agents
        self.island = island
    }

    var body: some View {
        let m = model.dropMetrics(island)
        let inset = m.ear + Spacing.edge
        ZStack(alignment: .topLeading) {
            if m.body > 0 { halo(inset: inset).transition(.opacity) }
            VStack(alignment: .leading, spacing: 0) {
                band.frame(height: model.notch.height)
                if m.body > 0 {
                    content
                        .padding(.top, Spacing.under)
                        .frame(height: m.body - Spacing.bottom, alignment: .top)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, inset)
        }
        .frame(width: m.width + 2 * m.ear, height: model.notch.height + m.body, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { primaryAction() }
        .contextMenu { menu }
        .animation(Motion.smooth, value: model.islandHovered)
        .onAppear {
            if case .call(let name, _) = island.kind { NotificationWatcher.contactImage(named: name) { callImage = $0 } }
        }
    }

    /// The icon lights the drop from inside: a soft halo close around it, never under the camera. An agent's
    /// halo takes its letter's colour: a green fog around a blue letter looked muddy and reached the corner.
    private func halo(inset: CGFloat) -> some View {
        let big = island.size(hovered: model.islandHovered) == .ask
        let center = CGPoint(x: inset + (big ? 13 : 20), y: model.notch.height + Spacing.under + (big ? 13 : 20))
        let tone: Color = if case .agentDone(let turn) = island.kind { AgentCursor.color(turn.project) } else { island.tone }
        return Circle()
            .fill(RadialGradient(stops: [.init(color: tone.opacity(0.3), location: 0),
                                         .init(color: tone.opacity(0.1), location: 0.45),
                                         .init(color: tone.opacity(0), location: 1)],
                                 center: .center, startRadius: 0, endRadius: big ? 60 : 75))
            .frame(width: big ? 120 : 150, height: big ? 120 : 150)
            .position(center)
            // The band beside the camera stays pure black; the light starts just under it.
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: model.notch.height)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Spacing.under)
                    Color.black
                }
            }
            .allowsHitTesting(false)
    }

    // MARK: Band beside the camera

    private var band: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) { bandLeft }
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notch.width + 2 * Spacing.clear)
            HStack(spacing: 6) {
                bandRight
                if model.islandQueue.count > 0 {
                    Text("+\(model.islandQueue.count)").font(.system(size: 10.5, weight: .heavy))
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .help(L("Ещё \(model.islandQueue.count) ждут: покажу следом"))
                }
                // Closes the drop at once; a request stays in the Agents tab and in the closed notch.
                if island.size(hovered: model.islandHovered) != .flash {
                    Button { model.dismissIsland() } label: {
                        Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white.opacity(0.75))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.icon)
                    .help("Закрыть")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.62))
        .lineLimit(1)
    }

    private func glyph(_ provider: String) -> some View {
        Text(provider == "codex" ? "◎" : "✳︎").foregroundStyle(Tone.ink)
    }

    @ViewBuilder private var bandLeft: some View {
        switch island.kind {
        case .agentDone(let turn):
            glyph(turn.provider)
            Text(turn.provider == "codex" ? "Codex" : "Claude")
        case .agentsDone(let turns):
            Text(Format.count(turns.count, "агент", "агента", "агентов")).foregroundStyle(.white)
        case .notification(let bundleID, let app, _, _):
            if let icon = NotificationWatcher.icon(for: bundleID) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
            Text(app)
        case .call(_, let bundleID):
            Image(systemName: "phone.fill").font(.system(size: 12)).foregroundStyle(Tone.done)
            Text(NotificationWatcher.appName(for: bundleID))
        case .airpods(let name, _), .airpodsAway(let name, _, _):
            Image(systemName: "headphones").font(.system(size: 13)).foregroundStyle(Tone.ink)
            Text(name).foregroundStyle(.white)
        case .download(let name, _):
            Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Tone.info)
            Text(name).foregroundStyle(.white).truncationMode(.middle)
        case .timerDone(let title, _):
            Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tone.focus)
            Text(title)
        case .event(_, let start, _):
            Text(start.formatted(date: .omitted, time: .shortened)).foregroundStyle(.white)
        case .command(_, _, let exit, _, _):
            Image(systemName: "terminal").font(.system(size: 12)).foregroundStyle(exit == 0 ? Tone.done : Tone.deny)
            Text("Команда")
        case .limit(let title, _, _):
            Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 12)).foregroundStyle(island.tone)
            Text(title)
        case .hog(let hog, _):
            Image(systemName: "cpu").font(.system(size: 12)).foregroundStyle(Tone.deny)
            Text(Self.cpuShare(hog)).foregroundStyle(Tone.deny)
        case .dictation:
            Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(Tone.meeting)
            Text("Диктовка")
        case .notice(let symbol, let title, _, let ok):
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(ok ? Tone.done : Tone.deny)
            Text(title).foregroundStyle(.white)
        case .request(let id):
            if let r = agents.permissions.first(where: { $0.id == id }) {
                glyph(r.provider.rawValue)
                Text("\(r.provider.title) · \(DropRequest.toolName(r))")
            }
        }
    }

    @ViewBuilder private var bandRight: some View {
        switch island.kind {
        case .agentDone(let turn):
            // The title already says "готово": the band tells how long the turn took and what it checked.
            if let fact = turn.summary.first(where: { $0.good != nil }) {
                Text(fact.text).foregroundStyle(fact.good == false ? Tone.deny : Tone.done)
            }
            if let duration = turn.duration { Text(Format.span(duration)) }
        case .agentsDone:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Tone.done)
            Text("готово").foregroundStyle(Tone.done)
        case .call:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(island.created))).font(.rounded(13, .heavy)).foregroundStyle(Tone.done)
                    .monospacedDigit()
            }
        case .airpods(_, let levels):
            if let low = levels.values.min() {
                RingGauge(fraction: Double(low) / 100, colors: [low <= 20 ? Tone.deny : Tone.done, low <= 20 ? Tone.deny : Tone.done], lineWidth: 2.5)
                    .frame(width: 18, height: 18)
                Text("\(low) %").font(.rounded(13, .heavy)).foregroundStyle(.white)
            }
        case .airpodsAway(_, _, let device):
            // Where they went, only when macOS names it.
            Image(systemName: device == nil ? "arrow.left.arrow.right" : "arrow.right").font(.system(size: 11, weight: .bold))
                .foregroundStyle(Tone.attention)
            if let device { Text(device).foregroundStyle(Tone.attention) }
        case .download:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Tone.done)
        case .timerDone:
            if model.timer.pomodoro {
                HStack(spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill(i < model.timer.completedFocus % 4 || (model.timer.completedFocus > 0 && model.timer.completedFocus % 4 == 0)
                                      ? Tone.focus : Color.white.opacity(0.2)).frame(width: 6, height: 6)
                    }
                }
            }
        case .event(_, let start, _):
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let left = start.timeIntervalSince(context.date)
                Text(left > 0 ? Format.until(left) : L("идёт")).font(.rounded(13.5, .heavy)).foregroundStyle(Tone.meeting)
            }
        case .command(_, let seconds, let exit, _, _):
            Text(exit == 0 ? Format.until(seconds) : L("код \(exit)")).foregroundStyle(exit == 0 ? Tone.done : Tone.deny)
        case .limit(_, let left, _):
            Text("\(left)%").font(.rounded(13.5, .heavy)).foregroundStyle(island.tone)
        case .hog:
            Text("больше 2 мин")
        case .notice(_, _, _, let ok) where ok:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Tone.done)
        case .request(let id):
            if let r = agents.permissions.first(where: { $0.id == id }) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let waited = context.date.timeIntervalSince(r.created)
                    Text(waited < 60 ? L("ждёт") : L("ждёт ") + Format.span(waited)).foregroundStyle(Tone.attention)
                }
                Circle().fill(Tone.attention).frame(width: 7, height: 7)
            }
        default:
            EmptyView()
        }
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        switch island.kind {
        case .agentsDone(let turns): DropTurns(model: model, turns: turns)
        case .request(let id):
            if let r = agents.permissions.first(where: { $0.id == id }) { DropRequest(model: model, agents: agents, request: r) }
        case .hog(let hog, let agent): hogBody(hog, agent: agent)
        default:
            VStack(alignment: .leading, spacing: Spacing.gap) {
                // On hover an agent's message goes on past its first line, in the same place: it is not repeated.
                let extra: CGFloat = if case .agentDone(let turn) = island.kind, model.islandHovered { Self.moreHeight(turn) } else { 0 }
                let more = extra > 0
                HStack(alignment: .top, spacing: 13) {
                    icon.frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        title.font(.system(size: 15, weight: .bold)).lineLimit(1)
                        subtitle.font(.system(size: 12.5)).foregroundStyle(.white.opacity(more ? 0.8 : 0.6))
                            .lineLimit(more ? 3 : 1)
                            .fixedSize(horizontal: false, vertical: more)
                        if more, case .agentDone(let turn) = island.kind, !turn.summary.isEmpty {
                            TurnFacts(facts: turn.summary).frame(height: 14).padding(.top, 4).transition(.opacity)
                        }
                    }
                    Spacer(minLength: 4)
                    actions.frame(height: 40)
                }
                .frame(height: 40 + extra, alignment: .top)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch island.kind {
        case .agentDone(let turn): Monogram(project: turn.project, size: 40)
        case .notification(let bundleID, _, _, _):
            if let icon = NotificationWatcher.icon(for: bundleID) { Image(nsImage: icon).resizable() } else { TileIcon(symbol: "bell.fill", color: Tone.info, size: 40) }
        case .call:
            if let callImage {
                Image(nsImage: callImage).resizable().scaledToFill().clipShape(Circle())
                    .overlay(Circle().strokeBorder(Tone.done.opacity(0.6), lineWidth: 2))
            } else {
                TileIcon(symbol: "phone.fill", color: Tone.done, size: 40)
            }
        case .airpods: TileIcon(symbol: "headphones", color: Tone.ink, size: 40)
        case .airpodsAway: TileIcon(symbol: "headphones", color: Tone.attention, size: 40)
        case .download: TileIcon(symbol: "arrow.down", color: Tone.info, size: 40)
        case .timerDone:
            ZStack {
                Circle().stroke(Tone.focus, lineWidth: 3.5)
                Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(Tone.focus)
            }
            .padding(2)
        case .event: TileIcon(symbol: "calendar", color: Tone.meeting, size: 40)
        case .command(_, _, let exit, _, _): TileIcon(symbol: exit == 0 ? "terminal.fill" : "exclamationmark.triangle.fill", color: island.tone, size: 40)
        case .limit: TileIcon(symbol: "gauge.with.dots.needle.67percent", color: island.tone, size: 40)
        case .dictation: TileIcon(symbol: "waveform", color: Tone.meeting, size: 40)
        case .notice(let symbol, _, _, _): TileIcon(symbol: symbol, color: island.tone, size: 40)
        default: EmptyView()
        }
    }

    @ViewBuilder private var title: some View {
        switch island.kind {
        case .agentDone(let turn): Text(turn.project) + Text(L(" готово")).foregroundColor(Tone.done)
        case .notification(_, _, let title, _): Text(title)
        case .call(let name, _): Text(name.isEmpty ? L("Входящий звонок") : name)
        case .airpods(let name, _), .airpodsAway(let name, _, _): Text(name)
        case .download(let name, _): Text(name).truncationMode(.middle)
        case .timerDone(_, let subtitle): Text(subtitle)
        case .event(let title, _, _): Text(title)
        case .command(let text, _, _, _, _): Text(text).font(.system(size: 13, weight: .semibold, design: .monospaced)).truncationMode(.middle)
        case .limit(let title, let left, _): Text(L("\(title): осталось \(left)%"))
        case .dictation(let title, _, _): Text(title)
        case .notice(_, let title, _, _): Text(title)
        default: EmptyView()
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch island.kind {
        case .agentDone(let turn): Text(turn.message.isEmpty ? L("ход завершён") : turn.message)
        case .notification(_, _, _, let body): Text(body.isEmpty ? L("новое сообщение") : body)
        case .call: Text("входящий звонок")
        case .airpods(_, let levels):
            Text(levels.isEmpty ? L("Подключены") : levels.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) %" }.joined(separator: " · "))
        case .airpodsAway(_, _, let device):
            Text(device.map { L("Переключились на \($0)") } ?? L("Переключились на другое устройство"))
        case .download: Text("Загружено")
        case .timerDone: Text(model.timer.pomodoro ? L("помодоро идёт дальше") : L("время вышло"))
        case .event(_, let start, let url):
            Text([start.formatted(date: .omitted, time: .shortened), url.map { Meeting.name($0) }].compactMap { $0 }.joined(separator: " · "))
        case .command(_, let seconds, let exit, _, _):
            Text((exit == 0 ? L("завершилась · шла ") : L("с ошибкой · шла ")) + Format.until(seconds))
        case .limit(_, _, let resets):
            Text(resets.map { L("сброс ") + Format.when($0) } ?? L("время сброса неизвестно"))
        case .dictation(_, let detail, _): Text(detail)
        case .notice(_, _, let detail, _): Text(detail)
        default: EmptyView()
        }
    }

    @ViewBuilder private var actions: some View {
        switch island.kind {
        case .agentDone(let turn):
            if let session = agents.sessions.first(where: { $0.id == turn.session }), agents.canReply(session) {
                Button("Ответить") { model.dismissIsland(showNext: false); model.startReply(to: turn.session) }
                    .buttonStyle(.pill(.primary, small: true))
                    .help("Написать агенту прямо из Nook. Клик по капле открывает вкладку «Агенты»")
            } else {
                Button("Терминал") { AgentHub.focus(pid: turn.pid, terminal: turn.terminal); model.dismissIsland() }
                    .buttonStyle(.pill(.ghost, small: true))
            }
        case .download(_, let path):
            HStack(spacing: 6) {
                Button("На полку") { model.shelf.add([URL(fileURLWithPath: path)]); model.dismissIsland() }.buttonStyle(.pill(.ghost, small: true))
                if Downloads.isRunnable(path) {
                    Button("В Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]); model.dismissIsland() }
                        .buttonStyle(.pill(.primary, small: true))
                        .help("Программы и скрипты из интернета Nook не открывает сам — проверьте файл в Finder")
                } else {
                    Button("Открыть") { NSWorkspace.shared.open(URL(fileURLWithPath: path)); model.dismissIsland() }
                        .buttonStyle(.pill(.primary, small: true))
                }
            }
        case .timerDone:
            // Pomodoro has already moved on to its next phase; 5 more minutes would replace it.
            if model.timer.pomodoro {
                Button("Стоп") { model.timer.reset(); model.dismissIsland() }.buttonStyle(.pill(.ghost, small: true))
            } else {
                Button("+5 мин") { model.timer.start(minutes: 5); model.dismissIsland() }.buttonStyle(.pill(.primary, small: true))
            }
        case .event(_, _, let url):
            if let url { Button("Войти") { NSWorkspace.shared.open(url); model.dismissIsland() }.buttonStyle(.pill(.go, small: true)) }
        case .command(_, _, _, let pid, let terminal):
            Button("Открыть") { AgentHub.focus(pid: pid, terminal: terminal); model.dismissIsland() }.buttonStyle(.pill(.ghost, small: true))
        case .call(_, let bundleID):
            Button("Открыть") { NotificationWatcher.open(bundleID: bundleID); model.dismissIsland() }.buttonStyle(.pill(.go, small: true))
        case .dictation(_, _, let settings) where settings:
            Button("Настройки") { model.dismissIsland(); model.onOpenSettings?(.dictation) }.buttonStyle(.pill(.ghost, small: true))
        case .airpodsAway(let name, let address, _):
            // The result comes as its own drop: the headphones with their battery, or why it failed.
            Button("Вернуть на Mac") { model.dismissIsland(); model.bluetooth.bringBack(address: address, name: name) }
                .buttonStyle(.pill(.primary, small: true))
                .help("Вернуть звук в наушники на этом Mac")
        case .airpods(_, let levels) where !levels.isEmpty:
            HStack(spacing: 10) {
                ForEach(levels.sorted { $0.key < $1.key }, id: \.key) { label, value in
                    VStack(spacing: 1) {
                        ZStack {
                            RingGauge(fraction: Double(value) / 100, colors: [value <= 20 ? Tone.deny : Tone.done, value <= 20 ? Tone.deny : Tone.done], lineWidth: 3)
                            Text("\(value)").font(.rounded(9.5, .heavy))
                        }
                        .frame(width: 26, height: 26)
                        Text(label).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func hogBody(_ hog: ProcessWatch.Hog, agent: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.gap) {
            HStack(spacing: 10) {
                TileIcon(symbol: hog.memory >= ProcessWatch.memoryLimit ? "memorychip.fill" : "cpu", color: Tone.deny, size: 26)
                (Text("Mac ") + Text(L("перегружен")).foregroundColor(Tone.deny) + Text(agent.map { L(" · агент в \($0)") } ?? ""))
                    .font(.system(size: 15, weight: .bold)).lineLimit(1)
            }
            .frame(height: 26)
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Text("$").foregroundStyle(.white.opacity(0.4))
                    Text(hog.command).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 12).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(hog.memory >= ProcessWatch.memoryLimit ? L("Память") : L("Процессор")).font(.system(size: 11.5)).foregroundStyle(muted)
                        Spacer()
                        Text(hog.memory >= ProcessWatch.memoryLimit ? ByteCountFormatter.string(fromByteCount: Int64(hog.memory), countStyle: .memory)
                                                                   : Self.cpuShare(hog))
                            .font(.rounded(13, .heavy)).foregroundStyle(Tone.deny)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(Tone.deny).frame(width: geo.size.width * Self.cpuFraction(hog))
                        }
                    }
                    .frame(height: 5)
                }
                .frame(width: 150)
            }
            .frame(height: 34)
            HStack(spacing: 6) {
                KillButton(hog: hog) { model.dismissIsland() }
                Button("Оставить") { model.dismissIsland() }.buttonStyle(.pill(.ghost, small: true))
            }
            .frame(height: 28)
        }
    }

    // MARK: Menu and click

    @ViewBuilder private var menu: some View {
        if case .notification(let bundleID, let app, _, _) = island.kind {
            Button("Не показывать от «\(app)»") {
                var muted = Settings.mutedApps
                muted.insert(bundleID)
                Settings.mutedApps = muted
                model.dismissIsland()
            }
        }
        if case .hog(let hog, _) = island.kind {
            Button("Не следить за «\(hog.name)»") {
                var ignored = Settings.ignoredProcesses
                ignored.insert(hog.name)
                Settings.ignoredProcesses = ignored
                model.dismissIsland()
            }
        }
        Button("Скрыть") { model.dismissIsland() }
    }

    /// A click on the drop opens the tab it belongs to; apps and terminals open themselves.
    private func primaryAction() {
        switch island.kind {
        case .agentDone, .agentsDone, .limit, .request: model.open(tab: .ai); return
        case .event: model.open(tab: .calendar); return
        case .timerDone: model.open(tab: .timer); return
        case .notification(let bundleID, _, _, _), .call(_, let bundleID): NotificationWatcher.open(bundleID: bundleID)
        case .download(_, let path): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .command(_, _, _, let pid, let terminal): AgentHub.focus(pid: pid, terminal: terminal)
        case .dictation(_, _, let settings):
            model.dismissIsland()
            if settings { model.onOpenSettings?(.dictation) }
            return
        // «Вернуть» is a button of its own: a click on the drop must not pull the headphones from the other device.
        case .airpods, .airpodsAway, .hog, .notice: break
        }
        model.dismissIsland()
    }

    // MARK: Words

    /// Share of the whole Mac, not of one core: "138 %" (1.4 cores) confused the user.
    static func cpuShare(_ hog: ProcessWatch.Hog) -> String {
        "\(Int((cpuFraction(hog) * 100).rounded())) %"
    }

    static func cpuFraction(_ hog: ProcessWatch.Hog) -> Double {
        min(1, max(0.01, Double(hog.cpu) / 100 / Double(ProcessInfo.processInfo.activeProcessorCount)))
    }

    /// "0:12".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Two or three agents that finished within a few seconds: one drop, a row each, a reply in each.
struct DropTurns: View {
    @ObservedObject var model: NotchModel
    let turns: [AgentTurn]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.gap) {
            ForEach(Array(turns.enumerated()), id: \.offset) { i, turn in
                if i > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, 41) }
                HStack(spacing: 11) {
                    Monogram(project: turn.project, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(turn.project).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                        Text(turn.message.isEmpty ? L("ход завершён") : turn.message).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let fact = turn.summary.first {
                        Text(fact.text).font(.system(size: 11, weight: .medium)).foregroundStyle(fact.good == false ? Tone.deny : Tone.done).lineLimit(1)
                    }
                    if let session = model.agents.sessions.first(where: { $0.id == turn.session }), model.agents.canReply(session) {
                        Button("Ответить") { model.dismissIsland(showNext: false); model.startReply(to: turn.session) }
                            .buttonStyle(.pill(.ghost, small: true))
                    }
                }
                .frame(height: 34)
            }
        }
    }
}

/// A request in a big drop: who asks and what, answered with buttons. A command longer than the drop can show
/// cannot be approved here — "Посмотреть" opens the panel with the whole text.
struct DropRequest: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var agents: AgentHub
    let request: AgentHub.Permission
    /// Buttons wake up a moment after the drop appears, so a click meant for something else cannot approve.
    @State private var armed = false
    /// Pieces of text (the command, or the plan's steps by index) measured as drawn in full. Until a piece is
    /// measured it counts as cut, so approval waits for the layout.
    @State private var whole: Set<Int> = []

    static func toolName(_ r: AgentHub.Permission) -> String {
        switch r.tool {
        case "AskUserQuestion": return L("вопрос")
        case "ExitPlanMode": return L("план")
        default: return r.tool
        }
    }

    /// The request's text without blank lines: the command, then every other field.
    static func shown(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Lines the command box is sized for: a line of more than about 60 characters wraps.
    static func lineCount(_ text: String) -> Int {
        shown(text).reduce(0) { $0 + max(1, Int((Double($1.count) / 60).rounded(.up))) }
    }

    /// The whole text is drawn in the drop, as measured from the layout (a wide character or a run of tabs is
    /// wider than a count of characters says); otherwise it can only be approved where it is shown in full.
    private var fits: Bool { Self.shown(request.summary).count <= 2 && whole.contains(0) }

    private func piece(_ index: Int) -> Binding<Bool> {
        Binding(get: { whole.contains(index) }, set: { if $0 { whole.insert(index) } else { whole.remove(index) } })
    }

    var body: some View {
        Group {
            switch request.tool {
            case "AskUserQuestion": question
            case "ExitPlanMode": plan
            default: permission
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation(Motion.quick) { armed = true } } }
    }

    private func header(_ words: String) -> some View {
        HStack(spacing: 10) {
            Monogram(project: request.project, size: 26)
            (Text(request.project + " ") + Text(words).foregroundColor(Tone.attention)).font(.system(size: 15, weight: .bold)).lineLimit(1)
        }
        .frame(height: 26)
    }

    private var permission: some View {
        let lines = Self.lineCount(request.summary)
        return VStack(alignment: .leading, spacing: Spacing.gap) {
            header(request.tool == "Bash" ? L("хочет выполнить") : L("просит разрешение"))
            HStack(alignment: .top, spacing: 9) {
                if request.tool == "Bash" { Text("$").foregroundStyle(.white.opacity(0.4)) }
                let text = Self.shown(request.summary).joined(separator: "\n")
                Text(text).lineLimit(2).truncationMode(.tail).reportsWhole(text, font: .system(size: 12, design: .monospaced), into: piece(0))
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(hex: 0xF2F2F5))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(height: lines > 1 ? 50 : 34, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
            .help(request.summary)
            HStack(spacing: 6) {
                if fits {
                    Button("Разрешить") { agents.answer(request.id, with: .allow) }.buttonStyle(.pill(.primary, small: true))
                    if request.suggestions != nil {
                        Button("Всегда") { agents.answer(request.id, with: .always) }.buttonStyle(.pill(.ghost, small: true))
                            .help(L("Добавит: ") + PermissionCard.describe(request.suggestions))
                    }
                    Button("Отклонить") { agents.answer(request.id, with: .deny) }.buttonStyle(.pill(.deny, small: true))
                } else {
                    Button("Посмотреть") { model.open(tab: .ai) }.buttonStyle(.pill(.primary, small: true))
                        .help("Команда длиннее, чем видно здесь: откроется целиком во вкладке «Агенты»")
                    Button("Отклонить") { agents.answer(request.id, with: .deny) }.buttonStyle(.pill(.deny, small: true))
                }
                Spacer(minLength: 0)
                TerminalButton { agents.answer(request.id, with: nil) }
            }
            .frame(height: 28)
            .disabled(!armed)
            .opacity(armed ? 1 : 0.55)
            if request.suggestions != nil {
                Text(L("«Всегда» добавит: ") + PermissionCard.describe(request.suggestions))
                    .font(.system(size: 10.5)).foregroundStyle(faint).lineLimit(1).truncationMode(.middle)
                    .frame(height: 13)
                    .padding(.top, Spacing.list - Spacing.gap)
            }
        }
    }

    /// `described`: some option has a description, which the drop has no room for.
    private struct Question { let text: String; let header: String; let options: [String]; let multi: Bool; let described: Bool }

    private var questions: [Question] {
        (request.input["questions"] as? [[String: Any]] ?? []).map { q in
            let options = q["options"] as? [[String: Any]] ?? []
            return Question(text: q["question"] as? String ?? "", header: q["header"] as? String ?? "",
                            options: options.compactMap { $0["label"] as? String },
                            multi: q["multiSelect"] as? Bool ?? false,
                            described: options.contains { !($0["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }

    private var question: some View {
        let all = questions
        // One simple question read in full: answer with a click. Anything more, a question cut short or options
        // with descriptions, is answered in the panel, where all of it is shown.
        let simple = all.count == 1 && !all[0].multi && !all[0].described && (1...4).contains(all[0].options.count)
        let q = all.first
        let title = AgentHub.revealed(q?.text ?? L("Вопрос"))
        return VStack(alignment: .leading, spacing: Spacing.gap) {
            HStack(spacing: 10) {
                Monogram(project: request.project, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                        .reportsWhole(title, font: .system(size: 15, weight: .bold), into: piece(0))
                    Text([request.project, q?.header].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12.5)).foregroundStyle(muted).lineLimit(1)
                }
            }
            .frame(height: 36)
            .help(q?.text ?? "")
            Group {
                if simple, whole.contains(0), let q {
                    // Every option at its full width, or none: a label cut short is not a choice you read.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            ForEach(q.options, id: \.self) { option in
                                Button(AgentHub.revealed(option)) {
                                    var input = request.input
                                    input["answers"] = [q.text: option]
                                    agents.answer(request.id, with: .allow, updatedInput: input)
                                }
                                .buttonStyle(.pill(.ghost, small: true))
                                .fixedSize()
                            }
                            Spacer(minLength: 0)
                            Button { model.open(tab: .ai) } label: {
                                HStack(spacing: 4) { Text("Своё"); Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold)) }
                            }
                            .buttonStyle(.icon).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
                            .fixedSize()
                            .help("Написать свой ответ во вкладке «Агенты»")
                        }
                        answerInPanel(count: all.count)
                    }
                } else {
                    answerInPanel(count: all.count)
                }
            }
            .frame(height: 30)
            .disabled(!armed)
            .opacity(armed ? 1 : 0.55)
        }
    }

    private func answerInPanel(count: Int) -> some View {
        HStack(spacing: 6) {
            Button(count > 1 ? L("Ответить на \(count) вопроса") : L("Ответить")) { model.open(tab: .ai) }
                .buttonStyle(.pill(.primary, small: true))
            Spacer(minLength: 0)
            TerminalButton { agents.answer(request.id, with: nil) }
        }
    }

    private var plan: some View {
        let lines = AgentHub.revealed(request.input["plan"] as? String ?? "").components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#-*• ")) }
            .filter { !$0.isEmpty }
        let steps = lines.prefix(3)
        let total = lines.count
        return VStack(alignment: .leading, spacing: Spacing.gap) {
            header(L("предлагает план"))
            VStack(alignment: .leading, spacing: Spacing.list) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.4))
                        Text(step).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                            .reportsWhole(step, font: .system(size: 12.5), into: piece(i))
                    }
                    .frame(height: 16)
                }
            }
            .frame(height: 60, alignment: .topLeading)
            HStack(spacing: 6) {
                // Approve only what you could read: a longer plan, or a step cut short, is approved in the panel.
                if total <= 3 && steps.indices.allSatisfy(whole.contains) {
                    Button("Одобрить") { agents.answer(request.id, with: .allow) }.buttonStyle(.pill(.primary, small: true))
                    Button("Весь план") { model.open(tab: .ai) }.buttonStyle(.pill(.ghost, small: true))
                } else {
                    Button("Посмотреть план") { model.open(tab: .ai) }.buttonStyle(.pill(.primary, small: true))
                        .help("План не помещается здесь целиком: откроется во вкладке «Агенты»")
                }
                Spacer(minLength: 0)
                TerminalButton { agents.answer(request.id, with: nil) }
            }
            .frame(height: 28)
            .disabled(!armed)
            .opacity(armed ? 1 : 0.55)
        }
    }
}

extension View {
    /// Reports whether `text`, laid out in `font` at this view's width, fits the height the view has: false when
    /// a line limit or a frame cut part of it off. Measured from the layout, not by counting characters. The copy
    /// drops the inherited line limit, or it would be cut the same way and always "fit".
    func reportsWhole(_ text: String, font: Font, into whole: Binding<Bool>) -> some View {
        background(alignment: .topLeading) {
            GeometryReader { box in
                Text(text).font(font).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .frame(width: box.size.width, alignment: .leading)
                    .hidden()
                    .background(GeometryReader { full in
                        let fits = full.size.height <= box.size.height + 1
                        Color.clear
                            .onAppear { whole.wrappedValue = fits }
                            .onChange(of: fits) { _, value in whole.wrappedValue = value }
                    })
            }
        }
    }
}
