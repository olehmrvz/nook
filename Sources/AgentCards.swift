import AppKit
import SwiftUI

/// Header shared by request cards: who asks, in which project, how long ago.
struct RequestHeader: View {
    let request: AgentHub.Permission
    let title: String
    var more = 0

    var body: some View {
        let claude = request.provider == .claude
        HStack(spacing: 10) {
            Text(claude ? "✳︎" : "◎").font(.system(size: 15, weight: .bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill((claude ? Palette.claude : Palette.blue).opacity(0.3)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(request.project) · \(request.created.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
            if more > 0 { Chip(text: "ещё \(more)", color: .white) }
        }
    }
}

/// "In terminal": leave the request to the agent's own dialog.
struct TerminalButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("В терминале")
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 12))
        }
        .buttonStyle(.icon).foregroundStyle(.white.opacity(0.7))
        .help("Ответить в терминале, как обычно")
    }
}

// MARK: AskUserQuestion

/// Claude's multiple-choice questions, answered from the notch. Answers go back as `answers`
/// (question text → chosen label; several labels joined with ", "), the same field the terminal dialog fills.
struct QuestionCard: View {
    let request: AgentHub.Permission
    @ObservedObject var agents: AgentHub
    var more = 0

    struct Question {
        let text: String
        let header: String
        let options: [(label: String, detail: String)]
        let multi: Bool
    }

    @State private var step = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: Set<String> = []
    @State private var custom = ""
    @State private var armed = false

    private var questions: [Question] {
        (request.input["questions"] as? [[String: Any]] ?? []).map { q in
            Question(text: q["question"] as? String ?? "",
                     header: q["header"] as? String ?? "",
                     options: (q["options"] as? [[String: Any]] ?? []).map {
                         ($0["label"] as? String ?? "", $0["description"] as? String ?? "")
                     },
                     multi: q["multiSelect"] as? Bool ?? false)
        }
    }

    var body: some View {
        let all = questions
        let current = all.indices.contains(step) ? all[step] : nil
        VStack(alignment: .leading, spacing: 7) {
            RequestHeader(request: request, title: Self.title(current, step: step, total: all.count), more: more)
            if let q = current {
                Text(q.text).font(.system(size: 13.5, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 3) {
                    ForEach(q.options, id: \.label) { option in optionRow(option, in: q, compact: q.options.count > 3) }
                }
                .disabled(!armed)
                HStack(spacing: 8) {
                    TextField(q.multi ? "Свой вариант (добавится к выбранным)" : "Свой ответ", text: $custom)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glass(radius: 9)
                        .onSubmit { submit(q, total: all.count) }
                    if q.multi || !custom.isEmpty {
                        Button(step == all.count - 1 ? "Ответить" : "Дальше") { submit(q, total: all.count) }
                            .buttonStyle(.pill(.primary, small: true))
                            .disabled(picked.isEmpty && custom.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    TerminalButton { agents.answer(request.id, with: nil) }
                }
            } else {
                // A shape Nook does not know: let the terminal handle it.
                Text("Nook не смог прочитать этот вопрос.").font(.system(size: 12)).foregroundStyle(muted)
                TerminalButton { agents.answer(request.id, with: nil) }
            }
        }
        .padding(12)
        .glass(tint: [Palette.claude.opacity(0.32), Palette.violet.opacity(0.08)], stroke: Palette.claude.opacity(0.4), radius: 22)
        .animation(Motion.smooth, value: step)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { armed = true } }
    }

    /// "Вопрос · Дизайн", "Вопрос 2 из 3 · Порядок".
    static func title(_ q: Question?, step: Int, total: Int) -> String {
        let number = total > 1 ? "Вопрос \(step + 1) из \(total)" : "Вопрос"
        guard let header = q?.header, !header.isEmpty else { return number }
        return "\(number) · \(header)"
    }

    private func optionRow(_ option: (label: String, detail: String), in q: Question, compact: Bool) -> some View {
        let on = picked.contains(option.label)
        return Button {
            if q.multi {
                if on { picked.remove(option.label) } else { picked.insert(option.label) }
            } else {
                picked = [option.label]
                submit(q, total: questions.count)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: q.multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 13)).foregroundStyle(on ? Palette.claude.lifted() : faint)
                Text(option.label).font(.system(size: 12.5, weight: .medium)).lineLimit(1).fixedSize()
                Text(option.detail).font(.system(size: 11.5)).foregroundStyle(muted).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, compact ? 3.5 : 5)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(on ? 0.12 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option.detail)
    }

    private func submit(_ q: Question, total: Int) {
        var chosen = q.options.map(\.label).filter(picked.contains)
        let typed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { chosen = q.multi ? chosen + [typed] : [typed] }
        guard !chosen.isEmpty else { return }
        answers[q.text] = chosen.joined(separator: ", ")
        picked = []
        custom = ""
        if step + 1 < total {
            step += 1
        } else {
            var input = request.input
            input["answers"] = answers
            agents.answer(request.id, with: .allow, updatedInput: input)
        }
    }
}

// MARK: ExitPlanMode

/// Plan review: approve, approve with edits accepted automatically, or send it back with a note.
struct PlanCard: View {
    let request: AgentHub.Permission
    @ObservedObject var agents: AgentHub
    var more = 0
    @State private var revising = false
    @State private var note = ""
    @State private var armed = false

    var body: some View {
        let plan = request.input["plan"] as? String ?? ""
        VStack(alignment: .leading, spacing: 10) {
            RequestHeader(request: request, title: "План готов — посмотрите", more: more)
            ScrollView(showsIndicators: true) {
                Text(Self.render(plan))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .textSelection(.enabled)
                    // Plan text comes from the agent: only web links open, never file:// or other schemes.
                    .environment(\.openURL, OpenURLAction { url in url.scheme == "https" ? .systemAction : .discarded })
            }
            .frame(height: revising ? 76 : 112)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35)))
            if revising {
                HStack(spacing: 8) {
                    TextField("Что поправить в плане?", text: $note)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glass(radius: 9)
                        .onSubmit(sendBack)
                    Button("Отправить", action: sendBack).buttonStyle(.pill(.primary, small: true))
                        .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Отмена") { revising = false }.buttonStyle(.pill(small: true))
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                HStack(spacing: 8) {
                    Button("Одобрить") { agents.answer(request.id, with: .allow) }.buttonStyle(.pill(.primary))
                    Button("Авто-правки") { agents.answer(request.id, with: .allow, mode: "acceptEdits") }
                        .buttonStyle(.pill())
                        .help("Одобрить и разрешить агенту править файлы без подтверждений до конца сессии")
                    Button("Доработать…") { revising = true }.buttonStyle(.pill(foreground: Palette.salmon))
                    Spacer(minLength: 0)
                    TerminalButton { agents.answer(request.id, with: nil) }
                }
                .disabled(!armed)
                .opacity(armed ? 1 : 0.55)
            }
        }
        .padding(14)
        .glass(tint: [Palette.violet.opacity(0.3), Palette.claude.opacity(0.1)], stroke: Palette.violet.opacity(0.45), radius: 22)
        .animation(Motion.smooth, value: revising)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation(Motion.quick) { armed = true } } }
    }

    private func sendBack() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        agents.answer(request.id, with: .deny, message: "Доработай план: \(text)")
    }

    /// Light markdown: headings become bold lines without "#", the rest keeps inline emphasis and code.
    static func render(_ plan: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = AttributedString()
        for (i, raw) in plan.components(separatedBy: "\n").enumerated() {
            if i > 0 { result.append(AttributedString("\n")) }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                var heading = AttributedString(trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                heading.font = .system(size: 12.5, weight: .bold)
                heading.foregroundColor = .white
                result.append(heading)
            } else {
                result.append((try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw))
            }
        }
        return result
    }
}
