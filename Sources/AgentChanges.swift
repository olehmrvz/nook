import Foundation

// MARK: What agents changed (Figma «Агенты · лента», concept C «Что изменилось»)
//
// The feed shows results, not tool calls: a file with the lines it gained and lost, tests with their numbers, a commit
// and its push, a command that failed. Reading and searching are not results and are not kept.

extension AgentHub {
    /// What one finished tool call changed.
    enum Outcome: Equatable {
        /// `path` is the key (two `page.tsx` in different folders are two rows); the row shows its name.
        case file(path: String, added: Int, removed: Int, created: Bool, deleted: Bool)
        /// Counts when the runner's summary was found in the output.
        case tests(passed: Int?, failed: Int?, ok: Bool, command: String)
        case commit(message: String)
        case push(branch: String?)
        case failed(what: String)
    }

    /// One row of the feed. Edits of one file in a session add up in one row; a push joins the commit before it.
    struct Change: Identifiable, Equatable {
        let id = UUID()
        let session: String
        let project: String
        var outcome: Outcome
        /// The branch a later push sent this commit to.
        var pushed: String?
    }

    static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"]
    static let shellTools: Set<String> = ["Bash", "shell", "exec_command", "local_shell"]

    /// Results of a finished call. `response` is the hook's `tool_response` (Claude Code: `structuredPatch` for
    /// edits, stdout / stderr for commands); without it the input alone gives the numbers.
    /// `interrupted`: the hook's `is_interrupt` (the person pressed Esc).
    static func outcomes(tool: String, input: [String: Any], response: Any?, ok: Bool, interrupted: Bool = false) -> [Outcome] {
        let reply = response as? [String: Any]
        if fileTools.contains(tool) {
            guard ok else { return [] }
            if tool == "apply_patch" { return patchOutcomes(patchText(input)) }
            guard let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String else { return [] }
            let created = reply?["type"] as? String == "create"
            var counts = reply.flatMap { patchCounts($0["structuredPatch"]) }
            if counts == nil || (counts! == (0, 0) && created) { counts = inputCounts(tool: tool, input: input) }
            let (added, removed) = counts ?? (0, 0)
            return [.file(path: path, added: added, removed: removed, created: created, deleted: false)]
        }
        guard shellTools.contains(tool) else { return [] }
        let command = (input["command"] as? String) ?? (input["command"] as? [String])?.joined(separator: " ")
            ?? (input["cmd"] as? String) ?? ""
        let output = Self.output(response)
        // Stopped with Esc or not allowed: nothing ran to the end, so no result — not even "tests failed".
        if !ok && (interrupted || reply?["interrupted"] as? Bool == true || declined(output)) { return [] }
        let checks = Self.checks(tool: tool, input: input)
        var found: [Outcome] = []
        if checks.contains("test") {
            let (passed, failed) = testCounts(output)
            found.append(.tests(passed: passed, failed: failed, ok: ok && (failed ?? 0) == 0, command: shortCommand(command)))
        }
        if checks.contains("commit"), ok { found.append(.commit(message: commitTitle(output: output, command: command))) }
        if checks.contains("push"), ok {
            let branch = ((reply?["gitOperation"] as? [String: Any])?["push"] as? [String: Any])?["branch"] as? String
            found.append(.push(branch: branch ?? pushedBranch(output)))
        }
        if found.isEmpty && !ok {
            found.append(.failed(what: (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? shortCommand(command)))
        }
        return found
    }

    /// "+" and "-" lines of Claude Code's hunks; nil when the response has none.
    private static func patchCounts(_ value: Any?) -> (Int, Int)? {
        guard let hunks = value as? [[String: Any]] else { return nil }
        var added = 0, removed = 0
        for hunk in hunks {
            for line in hunk["lines"] as? [String] ?? [] {
                if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
            }
        }
        return (added, removed)
    }

    private static func inputCounts(tool: String, input: [String: Any]) -> (Int, Int) {
        switch tool {
        case "Write": return (lines(input["content"] as? String ?? ""), 0)
        case "NotebookEdit": return (lines(input["new_source"] as? String ?? ""), 0)
        case "MultiEdit":
            return (input["edits"] as? [[String: Any]] ?? []).reduce((0, 0)) { sum, edit in
                let c = diff(edit["old_string"] as? String ?? "", edit["new_string"] as? String ?? "")
                return (sum.0 + c.0, sum.1 + c.1)
            }
        default: return diff(input["old_string"] as? String ?? "", input["new_string"] as? String ?? "")
        }
    }

    private static func lines(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
    }

    /// Lines added and removed going from `old` to `new`, like git counts them. Long texts are only counted.
    static func diff(_ old: String, _ new: String) -> (Int, Int) {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        guard a.count + b.count <= 2000 else { return (b.count, a.count) }
        let changes = b.difference(from: a)
        return (changes.insertions.count, changes.removals.count)
    }

    /// Codex's apply_patch: one outcome per file of the "*** Begin Patch" text.
    static func patchOutcomes(_ patch: String) -> [Outcome] {
        var found: [Outcome] = []
        var name: String?, added = 0, removed = 0, created = false, deleted = false
        func flush() {
            if let name { found.append(.file(path: name, added: added, removed: removed, created: created, deleted: deleted)) }
        }
        for line in patch.components(separatedBy: "\n") {
            let header = ["*** Add File: ", "*** Update File: ", "*** Delete File: "].first { line.hasPrefix($0) }
            if let header {
                flush()
                name = String(line.dropFirst(header.count)).trimmingCharacters(in: .whitespaces)
                added = 0; removed = 0; created = header.hasPrefix("*** Add"); deleted = header.hasPrefix("*** Delete")
            } else if line.hasPrefix("***") || line.hasPrefix("@@") {
                continue
            } else if line.hasPrefix("+") {
                added += 1
            } else if line.hasPrefix("-") {
                removed += 1
            }
        }
        flush()
        return found
    }

    private static func patchText(_ input: [String: Any]) -> String {
        for key in ["input", "patch", "command"] {
            if let text = input[key] as? String, text.contains("*** Begin Patch") { return text }
            if let parts = input[key] as? [String], let text = parts.first(where: { $0.contains("*** Begin Patch") }) { return text }
        }
        return ""
    }

    /// The text a command printed: stdout, stderr, an error. The end only: summaries are printed last.
    private static func output(_ response: Any?) -> String {
        let text: String
        if let plain = response as? String {
            text = plain
        } else if let reply = response as? [String: Any] {
            text = ["stdout", "stderr", "output", "error", "content"].compactMap { reply[$0] as? String }.joined(separator: "\n")
        } else {
            text = ""
        }
        return text.count > 20_000 ? String(text.suffix(20_000)) : text
    }

    /// Passed and failed counts from the summary line of common runners: jest / vitest / pytest
    /// ("39 passed, 2 failed"), XCTest ("Executed 41 tests, with 2 failures"); cargo prints one "test result:"
    /// line per test binary (the doc tests last, often "0 passed"), so its lines are added up.
    static func testCounts(_ output: String) -> (Int?, Int?) {
        if let cargo = try? NSRegularExpression(pattern: #"test result: \w+\. (\d+) passed; (\d+) failed"#) {
            let matches = cargo.matches(in: output, range: NSRange(output.startIndex..., in: output))
            if !matches.isEmpty {
                let sum = { (group: Int) in matches.reduce(0) { total, m in
                    total + (Range(m.range(at: group), in: output).flatMap { Int(output[$0]) } ?? 0) } }
                return (sum(1), sum(2))
            }
        }
        func last(_ pattern: String) -> [Int]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let range = NSRange(output.startIndex..., in: output)
            guard let match = regex.matches(in: output, range: range).last else { return nil }
            return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: output).flatMap { Int(output[$0]) } }
        }
        if let xc = last(#"Executed (\d+) tests?, with (\d+) failures?"#), xc.count == 2 { return (xc[0] - xc[1], xc[1]) }
        let passed = last(#"(\d+) (?:passed|passing)\b"#)?.first
        let failed = last(#"(\d+) (?:failed|failing)\b"#)?.first
        if passed == nil && failed == nil { return (nil, nil) }
        return (passed ?? 0, failed ?? 0)
    }

    /// "[main 1a2b3c4] Title" from git's own output, else the -m text, else nothing.
    static func commitTitle(output: String, command: String) -> String {
        if let regex = try? NSRegularExpression(pattern: #"^\[[^\]\n]+ [0-9a-f]{7,}\] (.+)$"#, options: [.anchorsMatchLines]),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output) {
            return String(output[range])
        }
        if let regex = try? NSRegularExpression(pattern: #"-m\s+(?:"((?:[^"\\]|\\.)*)"|'([^']*)')"#),
           let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) {
            for group in 1...2 {
                guard let range = Range(match.range(at: group), in: command) else { continue }
                var text = String(command[range])
                // `-m "$(cat <<'EOF' … EOF)"`: the first line of the heredoc.
                if text.hasPrefix("$(") { text = text.components(separatedBy: "\n").dropFirst().first ?? "" }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text.components(separatedBy: "\n")[0] }
            }
        }
        return ""
    }

    /// "   1a2b..3c4  main -> main": the branch on the remote.
    private static func pushedBranch(_ output: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"->\s+(\S+)"#),
              let match = regex.matches(in: output, range: NSRange(output.startIndex..., in: output)).last,
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }

    /// The person said no, or stopped it: not a failure of the command.
    private static func declined(_ output: String) -> Bool {
        ["doesn't want to proceed", "was rejected", "denied", "interrupted by user"].contains { output.localizedCaseInsensitiveContains($0) }
    }

    /// "npm test", "swift test --filter Foo": the command's first line, short.
    static func shortCommand(_ command: String) -> String {
        let line = command.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 48 ? String(line.prefix(48)) + "…" : line
    }
}
