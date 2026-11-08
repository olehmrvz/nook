import AppKit
import SwiftUI

// MARK: Agents (Figma «Агенты · Лента × плитки»)

/// Sessions as tiles on the left (a click shows only that session), on the right what the agents did: the
/// pending request, the answers of finished turns (AgentReply.swift), then files, tests and commits. The limits sit in
/// the caption above it.
struct AgentsTab: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var agents: AgentHub
    @ObservedObject var limits: Limits
    @ObservedObject var usage: Usage
    /// The session the feed is narrowed to; nil shows all.
    @State private var only: String?

    /// By state, then newest session first, which does not change: sorting by the last event made two working agents swap
    /// places on every tool call, and the tiles kept sliding over each other.
    private var sessions: [AgentHub.Session] {
        agents.sessions.enumerated()
            .sorted { $0.element.rank < $1.element.rank || ($0.element.rank == $1.element.rank && $0.offset < $1.offset) }
            .map(\.element)
    }

    var body: some View {
        Group {
            if agents.permissions.isEmpty && agents.sessions.isEmpty {
                empty
            } else {
                HStack(alignment: .top, spacing: Spacing.gap) {
                    sessionColumn.frame(width: 200).entrance(0)
                    // A caption row like the sessions' one: both columns' tiles start on one line.
                    VStack(alignment: .leading, spacing: Spacing.gap) {
                        feedHeader
                        feed
                    }
                    .entrance(1)
                }
            }
        }
        .onChange(of: agents.sessions.map(\.id)) { _, ids in if let only, !ids.contains(only) { self.only = nil } }
    }

    // MARK: Sessions

    private var sessionColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.gap) {
            HStack {
                Caps(text: L("Сессии"))
                Spacer()
                Button { withAnimation(Motion.quick) { only = nil } } label: {
                    Text(L("все · \(sessions.count)")).font(.system(size: 11, weight: .bold))
                        .foregroundStyle(only == nil ? Color.black : .white)
                        .padding(.horizontal, 9).frame(height: 20)
                        .background(Capsule().fill(only == nil ? Color.white.opacity(0.92) : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Показать в ленте все сессии")
            }
            .frame(height: 20)
            GeometryReader { geo in
                // Three tiles fill the column; more scroll at the same height.
                let height = (geo.size.height - 2 * Spacing.gap) / 3
                ScrollView(showsIndicators: false) {
                    VStack(spacing: Spacing.gap) {
                        ForEach(sessions) { s in
                            SessionTile(session: s, selected: only == s.id) {
                                withAnimation(Motion.quick) { only = only == s.id ? nil : s.id }
                            }
                            .frame(height: height)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .defaultScrollAnchor(.top)
            }
        }
        .animation(Motion.smooth, value: sessions.map(\.id))
    }

    // MARK: Feed

    /// The limits live in the caption, so the tile keeps its whole height for what the agents did; the line opens
    /// the details.
    private var feedHeader: some View {
        HStack(spacing: 12) {
            Caps(text: model.showLimits ? L("Лимиты · осталось") : L("Изменения"))
            Spacer(minLength: 8)
            LimitsLine(limits: limits, usage: usage, showsCost: false, isOpen: model.showLimits) {
                withAnimation(Motion.smooth) { model.showLimits.toggle() }
            }
            .fixedSize()
        }
        .frame(height: 20)
    }

    private var feed: some View {
        let request = agents.permissions.first { only == nil || $0.sessionKey == only }
        let waitingMore = agents.permissions.filter { only == nil || $0.sessionKey == only }.count - 1
        let changes = agents.changes.filter { only == nil || $0.session == only }
        let done = sessions.filter { $0.status == .done && (only == nil || $0.id == only) }
        // A question or a plan needs the whole tile: the tile itself becomes the card.
        let fillsTile = !model.showLimits && ["AskUserQuestion", "ExitPlanMode"].contains(request?.tool ?? "")
        return VStack(alignment: .leading, spacing: 8) {
            // The details take the feed's place inside the tile: a popover over it did not fit the tab's height.
            if model.showLimits {
                LimitsDetail(limits: limits, usage: usage, titled: false)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                feedContent(request: request, more: max(0, waitingMore), changes: changes, done: done)
                    .transition(.opacity)
            }
        }
        .padding(Spacing.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.requestFillsTile, fillsTile)
        .tile(fillsTile ? .attention : .plain)
        .animation(Motion.smooth, value: agents.permissions.map(\.id))
        .animation(Motion.smooth, value: agents.changes.map(\.id))
    }

    @ViewBuilder
    private func feedContent(request: AgentHub.Permission?, more: Int, changes: [AgentHub.Change],
                             done: [AgentHub.Session]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The oldest request stays pinned; no scrolling to reach its buttons.
            if let request {
                RequestSlot(request: request, agents: agents, more: more)
                    .id(request.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96, anchor: .top).combined(with: .opacity),
                                            removal: .scale(scale: 0.97).combined(with: .opacity)))
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    // What the agents answered comes first: that is what a finished turn is read for.
                    ForEach(done) { s in
                        let canReply = agents.canReply(s)
                        VStack(spacing: 6) {
                            ReplyCard(session: s, folded: done.count > 1 ? 50 : 66,
                                      onReply: canReply ? { model.startReply(to: s.id) } : nil)
                            if canReply && model.replyTo == s.id {
                                ReplyField(model: model, agents: agents, session: s)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    if !changes.isEmpty {
                        VStack(spacing: 0) { ForEach(changes) { ChangeRow(change: $0) } }
                    }
                    if changes.isEmpty && done.isEmpty && request == nil {
                        // Reading and searching are not shown: say why the feed is quiet.
                        let working = sessions.contains { $0.status == .working && (only == nil || $0.id == only) }
                        Text(working ? L("Агенты изучают код — правки, тесты и коммиты появятся здесь")
                                     : (only == nil ? L("Здесь появятся правки, тесты и коммиты агентов") : L("Эта сессия пока ничего не изменила")))
                            .font(.system(size: 12)).foregroundStyle(faint).padding(.top, 6).padding(.horizontal, 4)
                    }
                }
                .animation(Motion.smooth, value: model.replyTo)
            }
            .defaultScrollAnchor(.top)
            .frame(maxHeight: .infinity)
        }
    }

    private var empty: some View {
        Tile {
            VStack(spacing: 8) {
                // Limits come from local files and are there with no session too: the details open here as well.
                if model.showLimits {
                    LimitsDetail(limits: limits, usage: usage)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                } else {
                    noSessions.frame(maxHeight: .infinity).transition(.opacity)
                }
                LimitsLine(limits: limits, usage: usage, isOpen: model.showLimits) { withAnimation(Motion.smooth) { model.showLimits.toggle() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noSessions: some View {
        VStack(spacing: 8) {
            TileIcon(symbol: "sparkles", size: 40)
            Text("Нет активных сессий").font(.system(size: 15, weight: .semibold))
            Text(agents.hooksInstalled
                 ? L("Запустите Claude Code или Codex — статус и запросы на разрешение появятся здесь")
                 : L("Nook ещё не подключён к Claude Code и Codex"))
                .font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center)
            if !agents.hooksInstalled {
                Button("Подключить") {
                    // Writes the agents' settings files: not on the main thread. A failure is
                    // explained in Settings → Agents.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = AgentHub.installHooks()
                        DispatchQueue.main.async {
                            agents.checkHooks()
                            if !result.ok { model.onOpenSettings?(.agents) }
                        }
                    }
                }
                .buttonStyle(.pill(.primary, small: true))
                .help("Добавит хук Nook в ~/.claude/settings.json и ~/.codex/hooks.json, сохранив копии файлов")
            }
        }
    }
}

/// One session: its letter, project and state. A click narrows the feed; a double click opens its terminal.
struct SessionTile: View {
    let session: AgentHub.Session
    let selected: Bool
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        let kind: TileBackground.Kind = selected ? .selected : (session.needsYou ? .attention : .plain)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Monogram(project: session.project, size: 20, lit: session.status == .working || session.needsYou)
                Text(session.project).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                Spacer(minLength: 2)
                SessionIndicator(status: session.status).frame(width: 16, height: 14)
            }
            HStack(spacing: 4) {
                Text(word).font(.system(size: 11.5, weight: .bold)).foregroundStyle(session.stateColorNew)
                if !detail.isEmpty { Text("· " + detail).font(.system(size: 11.5)).foregroundStyle(muted) }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, Spacing.pad).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .tile(kind)
        .brightness(hover ? 0.04 : 0)
        .contentShape(RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
        .onTapGesture(count: 2) { AgentHub.focus(pid: session.pid, terminal: session.terminal) }
        .onTapGesture(perform: select)
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        .contextMenu {
            Button(session.terminal?["HERDR_TAB_ID"] != nil ? L("Открыть вкладку herdr") : L("Открыть терминал")) {
                AgentHub.focus(pid: session.pid, terminal: session.terminal)
            }
        }
        .help(L("Нажмите — в ленте только эта сессия; дважды — открыть её терминал"))
    }

    private var word: String {
        switch session.status {
        case .working: return L("работает")
        case .waiting, .attention: return L("ждёт тебя")
        case .done: return L("готово")
        case .idle: return L("ожидает")
        }
    }

    private var detail: String {
        switch session.status {
        case .working, .waiting, .attention: return session.shortTime
        case .done: return session.edited.isEmpty ? "" : Format.count(session.edited.count, "файл", "файла", "файлов")
        case .idle: return Format.span(Date().timeIntervalSince(session.updated)) + L(" назад")
        }
    }
}

extension AgentHub.Session {
    /// The state's colour in the redesign: yellow waits for you, green is done.
    var stateColorNew: Color {
        switch status {
        case .working: return .white
        case .waiting, .attention: return Tone.attention
        case .done: return Tone.done
        case .idle: return faint
        }
    }
}

/// One result: a file with the lines it gained and lost, tests with their numbers, a commit and its push, a command
/// that failed.
struct ChangeRow: View {
    let change: AgentHub.Change

    var body: some View {
        HStack(spacing: 9) {
            Monogram(project: change.project, size: 18, lit: false)
            Text(change.project).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(width: 80, alignment: .leading)
            icon.frame(width: 14, height: 14)
            text.font(.system(size: 12)).foregroundStyle(Tone.ink).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory.font(.system(size: 11, design: .monospaced)).lineLimit(1).fixedSize()
        }
        .frame(height: 24)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var icon: some View {
        switch change.outcome {
        case .file(_, _, _, let created, let deleted):
            Image(systemName: deleted ? "trash" : (created ? "plus" : "pencil")).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(deleted ? Tone.deny : Tone.info)
        case .tests(_, _, let ok, _):
            Image(systemName: ok ? "checkmark" : "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(ok ? Tone.done : Tone.deny)
        case .commit: CommitGlyph()
        case .push: Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
        case .failed: Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tone.deny)
        }
    }

    private var text: Text {
        switch change.outcome {
        case .file(let path, _, _, _, _): return Text((path as NSString).lastPathComponent)
        case .tests(let passed, let failed, let ok, _):
            if ok { return Text(passed.map { L("тесты прошли · \($0)") } ?? L("тесты прошли")) }
            if let failed, let passed, failed > 0 { return Text(L("тесты упали · \(failed) из \(passed + failed)")) }
            return Text("тесты упали")
        case .commit(let message): return Text(message.isEmpty ? L("коммит") : L("коммит «\(message)»"))
        case .push(let branch): return Text(branch.map { L("push · \($0)") } ?? "push")
        case .failed(let what): return Text(L("не вышло: \(what)"))
        }
    }

    @ViewBuilder private var accessory: some View {
        switch change.outcome {
        case .file(_, let added, let removed, let created, let deleted):
            HStack(spacing: 6) {
                if deleted { Text("удалён").foregroundStyle(faint) }
                if created { Text("новый").foregroundStyle(faint) }
                if added > 0 { Text("+\(added)").foregroundStyle(Tone.done) }
                if removed > 0 { Text("−\(removed)").foregroundStyle(Tone.deny) }
            }
        case .tests(_, _, _, let command):
            Text(command).foregroundStyle(faint).truncationMode(.middle).frame(maxWidth: 150, alignment: .trailing)
        case .commit:
            if let branch = change.pushed {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up").font(.system(size: 9.5, weight: .semibold))
                    Text(branch.isEmpty ? "push" : "push · \(branch)")
                }
                .foregroundStyle(muted)
            }
        default:
            EmptyView()
        }
    }
}

/// git's commit mark: a ring on a line.
private struct CommitGlyph: View {
    var body: some View {
        ZStack {
            Capsule().fill(Tone.ink).frame(width: 14, height: 1.6)
            Circle().fill(Surface.tile).frame(width: 7, height: 7)
            Circle().strokeBorder(Tone.ink, lineWidth: 1.6).frame(width: 7, height: 7)
        }
    }
}

/// A permission in one line while its command is that short; the full card when it is not (or on a click), and
/// always for questions and plans.
struct RequestSlot: View {
    let request: AgentHub.Permission
    @ObservedObject var agents: AgentHub
    var more = 0
    @State private var expanded = false

    var body: some View {
        // Claude Code sends a description with almost every command: the agent's words about it, not what runs, so
        // it goes into the tooltip. Any other field needs the full card.
        let lines = DropRequest.shown(request.summary)
        let inLine = !["AskUserQuestion", "ExitPlanMode"].contains(request.tool) && !lines.isEmpty
            && lines.dropFirst().allSatisfy { $0.hasPrefix("description: ") } && lines.count <= 2
        if inLine && !expanded {
            RequestLine(request: request, agents: agents, more: more) { withAnimation(Motion.smooth) { expanded = true } }
                .transition(.opacity)
        } else {
            RequestCard(request: request, agents: agents, more: more).transition(.opacity)
        }
    }
}

/// Who asks and the command, with «Отклонить» and «Разрешить». Approve only what is drawn whole: a command cut
/// short gets «Посмотреть», which opens the full card.
struct RequestLine: View {
    let request: AgentHub.Permission
    @ObservedObject var agents: AgentHub
    var more = 0
    let expand: () -> Void
    /// Buttons wake up a moment after the line appears, so a click meant for something else cannot approve.
    @State private var armed = false
    @State private var whole = false

    var body: some View {
        let command = DropRequest.shown(request.summary).first ?? ""
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 9) {
            Monogram(project: request.project, size: 18)
            Text(request.project).font(.system(size: 12.5, weight: .bold)).lineLimit(1).fixedSize()
            // Two lines at most: a command that needs more opens the full card.
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(request.tool == "Bash" ? "$ " : request.tool + " ").foregroundStyle(faint)
                Text(command).foregroundStyle(Color(hex: 0xF2F2F5)).lineLimit(2).truncationMode(.tail)
                    .reportsWhole(command, font: .system(size: 11, design: .monospaced), into: $whole)
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: expand)
            .help(request.summary)
            if more > 0 { Chip(text: "+\(more)", color: Tone.attention).help(L("Ещё \(more) ждут ответа")) }
            HStack(spacing: 6) {
                Button("Отклонить") { agents.answer(request.id, with: .deny) }.buttonStyle(.pill(.ghost, small: true))
                if whole {
                    Button("Разрешить") { agents.answer(request.id, with: .allow) }.buttonStyle(.pill(.primary, small: true))
                } else {
                    Button("Посмотреть", action: expand).buttonStyle(.pill(.primary, small: true))
                        .help("Команда не видна целиком: откроется полностью")
                }
            }
            .disabled(!armed)
            .opacity(armed ? 1 : 0.55)
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
        .frame(minHeight: 34)
        .background(shape.fill(LinearGradient(colors: [Tone.attention.opacity(0.07), Surface.tile],
                                              startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.6)))
            .overlay(shape.strokeBorder(Tone.attention.opacity(0.5))))
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation(Motion.quick) { armed = true } } }
    }
}

/// The background of a request inside the feed: graphite with a yellow edge, the only warm thing on screen.
/// None when the feed tile itself is the card (`requestFillsTile`).
struct RequestBackground: ViewModifier {
    @Environment(\.requestFillsTile) private var fillsTile

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if fillsTile {
            content
        } else {
            content
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(shape.fill(LinearGradient(colors: [Tone.attention.opacity(0.07), Surface.tile],
                                                      startPoint: .topLeading, endPoint: UnitPoint(x: 0.6, y: 0.6)))
                    .overlay(shape.strokeBorder(Tone.attention.opacity(0.5))))
        }
    }
}

private struct RequestFillsTileKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// A question or a plan takes the whole feed tile, which gets the yellow edge: a card inside it, with its own
    /// padding and border, did not fit four options under the feed's caption.
    var requestFillsTile: Bool {
        get { self[RequestFillsTileKey.self] }
        set { self[RequestFillsTileKey.self] = newValue }
    }
}

extension View {
    func requestCard() -> some View { modifier(RequestBackground()) }
}
