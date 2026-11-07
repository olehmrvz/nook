import SwiftUI

/// One limit window as the panel shows it: what is left and whether it will run out before it resets.
struct LimitWindow: Identifiable, Equatable {
    enum State { case ok, pace, low }
    let provider: AgentHub.Provider
    /// "5 ч", "нед", "мес", or what the service reports ("12 ч").
    let label: String
    let title: String
    /// Percent left, 0…100.
    let left: Int
    let resetsAt: Date?
    let length: TimeInterval
    var id: String { "\(provider.rawValue).\(label)" }

    var state: State {
        if left < 10 { return .low }
        // Spending ahead of time: at this pace the window runs out before it resets.
        if let resetsAt, length > 0 {
            let elapsed = 1 - min(max(resetsAt.timeIntervalSinceNow / length, 0), 1)
            if Double(100 - left) / 100 > elapsed + 0.12 { return .pace }
        }
        return .ok
    }

    var color: Color {
        switch state {
        case .ok: return Tone.limit
        case .pace: return Tone.attention
        case .low: return Tone.deny
        }
    }
}

extension Limits {
    /// Every window the services report, Claude first. Empty when nothing has come in yet.
    var windows: [LimitWindow] {
        func make(_ w: UsageWindow?, _ provider: AgentHub.Provider, _ label: String, _ title: String, _ length: TimeInterval) -> LimitWindow? {
            guard let w else { return nil }
            return LimitWindow(provider: provider, label: label, title: title, left: Int(max(0, 100 - w.usedPercent).rounded()),
                               resetsAt: w.resetsAt, length: length)
        }
        let minutes = codexWindowMinutes
        let codex: (String, String) = switch minutes {
        case 0: (L("окно"), L("Окно"))
        case 7 * 24 * 60: (L("нед"), L("Неделя"))
        case 28 * 24 * 60...31 * 24 * 60: (L("мес"), L("Месяц"))
        case ..<(24 * 60): (L("\(max(1, minutes / 60)) ч"), L("\(max(1, minutes / 60)) часов"))
        default: (L("\(minutes / (24 * 60)) дн"), L("\(minutes / (24 * 60)) дней"))
        }
        return [make(claudeSession, .claude, L("5 ч"), L("5 часов"), 5 * 3600),
                make(claudeWeek, .claude, L("нед"), L("Неделя"), 7 * 86400),
                make(codexPrimary, .codex, codex.0, codex.1, TimeInterval(minutes * 60))].compactMap { $0 }
    }
}

extension AgentHub.Provider {
    /// Claude and Codex look alike; the glyph alone tells them apart.
    var glyph: String { self == .claude ? "✳︎" : "◎" }
}

/// One window: label, a short bar, what is left; "↑" when it is being spent faster than time passes.
struct LimitPiece: View {
    let window: LimitWindow

    var body: some View {
        HStack(spacing: 5) {
            Text(window.label).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(window.color).frame(width: 30 * CGFloat(window.left) / 100)
            }
            .frame(width: 30, height: 4)
            Text("\(window.left)%").font(.rounded(11.5, .heavy))
                .foregroundStyle(window.state == .ok ? Color.white : window.color)
                .contentTransition(.numericText())
            if window.state == .pace {
                Text("↑").font(.system(size: 10, weight: .bold)).foregroundStyle(Tone.attention).padding(.leading, -3)
            }
        }
        .help(hint)
    }

    private var hint: String {
        let reset = window.resetsAt.map { L(", сброс ") + $0.formatted(.relative(presentation: .named)) } ?? ""
        return L("\(window.provider.title) · \(window.title): осталось \(window.left)%") + reset
    }
}

/// Every service in one line: its glyph and its windows, then today's cost. The line opens the details.
struct LimitsLine: View {
    @ObservedObject var limits: Limits
    @ObservedObject var usage: Usage
    var showsCost = true
    /// The details are shown: the chevron points down to close them.
    var isOpen = false
    var open: (() -> Void)?

    var body: some View {
        let windows = limits.windows
        let groups = [AgentHub.Provider.claude, .codex].map { p in (p, windows.filter { $0.provider == p }) }.filter { !$0.1.isEmpty }
        Button { open?() } label: {
            HStack(spacing: 14) {
                if groups.isEmpty {
                    Text("Лимиты появятся, когда агент начнёт работу").font(.system(size: 11)).foregroundStyle(faint).lineLimit(1)
                }
                ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
                    if i > 0 { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 14) }
                    HStack(spacing: 8) {
                        Text(group.0.glyph).font(.system(size: 12)).foregroundStyle(Tone.ink)
                        ForEach(Array(group.1.enumerated()), id: \.element.id) { j, w in
                            if j > 0 { Circle().fill(Color.white.opacity(0.25)).frame(width: 3, height: 3) }
                            LimitPiece(window: w)
                        }
                    }
                }
                Spacer(minLength: 0)
                if showsCost && usage.today.cost > 0 {
                    Text(Format.dollars(usage.today.cost) + L(" сегодня"))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
                if opens {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(faint)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!opens)
    }

    /// Nothing to show behind an empty line; open details still close.
    private var opens: Bool { open != nil && (isOpen || !limits.windows.isEmpty) }
}

/// The details behind the line, in place of the feed: a column per service, each window with its bar, the
/// even-pace mark and when it resets. Sized for the feed tile (about 200 pt high), never scrolled.
struct LimitsDetail: View {
    @ObservedObject var limits: Limits
    @ObservedObject var usage: Usage
    /// false where a caption above already names them (the Agents feed).
    var titled = true

    var body: some View {
        let windows = limits.windows
        let providers = [AgentHub.Provider.claude, .codex].filter { p in windows.contains { $0.provider == p } }
        VStack(alignment: .leading, spacing: 12) {
            if titled {
                HStack(alignment: .firstTextBaseline) {
                    Text("Лимиты · осталось").font(.system(size: 13, weight: .bold))
                    Spacer(minLength: 8)
                    if usage.today.tokens > 0 {
                        Text(L("сегодня ") + Format.tokens(usage.today.tokens))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                }
            }
            if windows.isEmpty {
                Text("Лимиты ещё не пришли: они появятся, когда Claude Code или Codex начнут работу.")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            HStack(alignment: .top, spacing: 22) {
                ForEach(providers, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text(p.glyph).font(.system(size: 11)).foregroundStyle(Tone.ink)
                            Caps(text: p.title)
                        }
                        ForEach(windows.filter { $0.provider == p }) { row($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Spacer(minLength: 0)
            if !windows.isEmpty {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.white).frame(width: 2, height: 9)
                    Text("ровный темп: если полоса короче метки, лимит кончится до сброса")
                        .font(.system(size: 10.5)).foregroundStyle(faint).lineLimit(1).truncationMode(.tail)
                    // Without a title the day's use goes here (the Agents feed shows the line without its cost).
                    if !titled && usage.today.tokens > 0 {
                        Spacer(minLength: 8)
                        Text(L("сегодня ") + Format.tokens(usage.today.tokens) + " " + Format.dollars(usage.today.cost))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(_ w: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(w.title).font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 6)
                Text("\(w.left)%").font(.rounded(12.5, .heavy)).foregroundStyle(w.state == .ok ? Color.white : w.color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(w.color).frame(width: geo.size.width * CGFloat(w.left) / 100)
                    // Where "left" would be at an even pace: past this mark the window runs out early.
                    if let reset = w.resetsAt, w.length > 0 {
                        let even = min(max(reset.timeIntervalSinceNow / w.length, 0), 1)
                        RoundedRectangle(cornerRadius: 1).fill(Color.white).frame(width: 2, height: 9)
                            .offset(x: geo.size.width * even - 1)
                    }
                }
            }
            .frame(height: 5)
            if let reset = w.resetsAt {
                let until = L("через ") + Format.until(reset.timeIntervalSinceNow)
                // The whole line when the column is wide enough, else only how long is left.
                ViewThatFits(in: .horizontal) {
                    Text(L("сброс ") + Format.when(reset) + " · " + until)
                    Text(until)
                }
                .font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                .help(L("сброс ") + Format.when(reset))
            }
        }
    }
}
