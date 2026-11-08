import AppKit
import SwiftUI

// MARK: Agent replies

/// A finished turn in the Agents feed: the project, how long the turn ran and what it did, what you asked, then the
/// agent's answer as it wrote it (lists, code, tables). A long answer opens a few lines tall and unfolds on a click.
/// A question at the end stays in sight under it, with the yellow edge of "ждёт тебя": that is what the agent waits for.
struct ReplyCard: View {
    let session: AgentHub.Session
    /// Height of the folded answer: four lines when the card is alone, three when several turns are done. With the
    /// header, your prompt and a question it leaves the next row of the feed in sight.
    var folded: CGFloat = 66
    var onReply: (() -> Void)?
    @State private var expanded = false
    /// The answer's full height, measured; it folds only when that is clearly more than `folded`.
    @State private var full: CGFloat = 0
    @State private var copied = false

    private var text: String { session.reply ?? session.lastMessage ?? "" }

    var body: some View {
        let reply = ReplyMarkdown.parse(text)
        let long = full > folded + 12
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            header(long: long)
            if let prompt = session.prompt, !prompt.isEmpty {
                (Text(L("Вы: ")).foregroundStyle(faint) + Text(prompt).foregroundStyle(muted))
                    .font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
            }
            if !reply.blocks.isEmpty {
                ReplyText(blocks: reply.blocks)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { box in
                        Color.clear
                            .onAppear { full = box.size.height }
                            .onChange(of: box.size.height) { _, height in full = height }
                    })
                    .frame(height: long && !expanded ? folded : nil, alignment: .top)
                    .clipped()
                    .mask {
                        if long && !expanded {
                            LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                        } else {
                            Rectangle()
                        }
                    }
                    // Folded, the whole answer is one target; unfolded, its links take the clicks.
                    .contentShape(Rectangle())
                    .onTapGesture { if long && !expanded { toggle() } }
            }
            if let question = reply.question {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "questionmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(Tone.attention)
                    Text(question).font(.system(size: 12.5)).foregroundStyle(Tone.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Tone.attention.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Tone.attention.opacity(0.45))))
                    .help("Агент спрашивает: ответьте здесь или в его терминале")
            }
            // Unfolded, the header's button may have scrolled away: one more at the end.
            if long && expanded {
                Button(action: toggle) {
                    HStack(spacing: 4) {
                        Text(L("Свернуть"))
                        Image(systemName: "chevron.up").font(.system(size: 8.5, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 9)
        .background(shape.fill(Color.white.opacity(0.04)).overlay(shape.strokeBorder(Tone.done.opacity(0.22))))
        .onChange(of: session.reply) { expanded = false }
        .contextMenu {
            Button(L("Скопировать ответ"), action: copy).disabled(text.isEmpty)
            Button(session.terminal?["HERDR_TAB_ID"] != nil ? L("Открыть вкладку herdr") : L("Открыть терминал")) {
                AgentHub.focus(pid: session.pid, terminal: session.terminal)
            }
        }
    }

    /// Project, "готово за 12 мин", what the turn did; unfold, copy and reply on the right. A click opens the terminal.
    private func header(long: Bool) -> some View {
        HStack(spacing: 9) {
            HStack(spacing: 9) {
                Monogram(project: session.project, size: 18, lit: false)
                Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text(finished)
                }
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Tone.done).fixedSize()
                ForEach(AgentHub.facts(session), id: \.self) { fact in
                    HStack(spacing: 3) {
                        Image(systemName: fact.symbol).font(.system(size: 9, weight: .bold))
                        Text(fact.text)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(fact.good == true ? Tone.done : (fact.good == false ? Tone.deny : muted))
                    .fixedSize()
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { AgentHub.focus(pid: session.pid, terminal: session.terminal) }
            .help(L("Нажмите — откроется терминал агента"))
            if long {
                Button(action: toggle) {
                    HStack(spacing: 4) {
                        Text(expanded ? L("Свернуть") : L("Весь ответ"))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8.5, weight: .bold))
                    }
                }
                .buttonStyle(.pill(.ghost, small: true))
            }
            if !text.isEmpty {
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 13)
                }
                .buttonStyle(.pill(.ghost, small: true))
                .help("Скопировать ответ целиком")
            }
            if let onReply {
                Button("Ответить", action: onReply).buttonStyle(.pill(.ghost, small: true))
                    .help("Написать агенту прямо отсюда: текст уйдёт в его терминал")
            }
        }
    }

    /// "готово за 12 мин"; just "готово" when the length is unknown or a few seconds.
    private var finished: String {
        guard let took = session.took, took >= 5 else { return L("готово") }
        return L("готово за \(Format.span(took))")
    }

    private func toggle() { withAnimation(Motion.smooth) { expanded.toggle() } }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(Motion.quick) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Motion.quick) { copied = false } }
    }
}

/// An answer's blocks, drawn in the feed's type: text at 12.5 pt, headings in white, list markers faint, code on a
/// darker plate, tables as a grid.
struct ReplyText: View {
    let blocks: [ReplyMarkdown.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(block) }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Tone.ink)
        .lineSpacing(1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(_ block: ReplyMarkdown.Block) -> some View {
        switch block {
        case .text(let text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case .heading(let text):
            Text(text).fontWeight(.semibold).foregroundStyle(.white).padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(faint).frame(minWidth: 10, alignment: .trailing)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote(let text):
            Text(text).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 9)
                .overlay(alignment: .leading) { Capsule().fill(Color.white.opacity(0.18)).frame(width: 2) }
        case .code(let code):
            Text(code).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tone.ink.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).fontWeight(i == 0 ? .semibold : .regular).foregroundStyle(i == 0 ? muted : Tone.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        case .rule:
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.vertical, 2)
        }
    }
}

/// The markdown agents answer in, split into the blocks Nook draws. Inline marks (bold, `code`, links) are left to
/// `AttributedString`; blocks are found line by line, which covers what Claude Code and Codex write.
enum ReplyMarkdown {
    enum Block: Hashable {
        case text(AttributedString)
        case heading(AttributedString)
        case item(marker: String, text: AttributedString, depth: Int)
        case quote(AttributedString)
        case code(String)
        case table([[AttributedString]])
        case rule
    }

    struct Parsed {
        let blocks: [Block]
        /// The last paragraph when it asks something: the card keeps it in sight.
        let question: AttributedString?
    }

    /// The feed redraws on every hook event; the same answer is parsed once. Main thread only.
    private static var cache: [String: Parsed] = [:]

    static func parse(_ markdown: String) -> Parsed {
        if let hit = cache[markdown] { return hit }
        let parsed = make(markdown)
        if cache.count >= 16 { cache.removeAll() }
        cache[markdown] = parsed
        return parsed
    }

    private enum Open { case paragraph([String]), item(marker: String, lines: [String], depth: Int) }

    private static func make(_ markdown: String) -> Parsed {
        var blocks: [Block] = []
        var open: Open?
        var code: [String]?
        var table: [[AttributedString]] = []

        func close() {
            switch open {
            case .paragraph(let lines): blocks.append(.text(inline(lines.joined(separator: " "))))
            case .item(let marker, let lines, let depth): blocks.append(.item(marker: marker, text: inline(lines.joined(separator: " ")), depth: depth))
            case nil: break
            }
            open = nil
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    close()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { close(); continue }

            if line.hasPrefix("|") && line.dropFirst().contains("|") {
                if open != nil { close() }
                // The |---|:---| line under the header carries no text.
                if line.allSatisfy({ "|-: ".contains($0) }) { continue }
                var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                table.append(cells.map(inline))
                continue
            }
            if !table.isEmpty { close() }

            if let match = line.firstMatch(of: #/^#{1,6}\s+(.+)$/#) {
                close()
                blocks.append(.heading(inline(String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "# ")))))
            } else if line.wholeMatch(of: #/(?:-{3,}|\*{3,}|_{3,})/#) != nil {
                close()
                blocks.append(.rule)
            } else if let match = raw.firstMatch(of: #/^(\s*)([-*+•]|\d{1,3}[.)])\s+(.+)$/#) {
                close()
                let marker = String(match.2)
                let indent = match.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                open = .item(marker: marker.first?.isNumber == true ? marker : "•", lines: [String(match.3)], depth: min(indent / 2, 3))
            } else if let match = line.firstMatch(of: #/^>\s?(.*)$/#) {
                close()
                blocks.append(.quote(inline(String(match.1))))
            } else {
                switch open {
                // An indented line under a list item continues it.
                case .item(let marker, let lines, let depth) where raw.first?.isWhitespace == true:
                    open = .item(marker: marker, lines: lines + [line], depth: depth)
                case .paragraph(let lines):
                    open = .paragraph(lines + [line])
                default:
                    close()
                    open = .paragraph([line])
                }
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        close()

        var question: AttributedString?
        if case .text(let last) = blocks.last, String(last.characters).trimmingCharacters(in: .whitespaces).hasSuffix("?") {
            question = last
            blocks.removeLast()
        }
        return Parsed(blocks: blocks, question: question)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
