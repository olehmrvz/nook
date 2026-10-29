import Foundation

/// Tokens and API-equivalent cost from Claude Code transcripts (`~/.claude/projects/*/…jsonl`, subagents included).
/// Local files only. Files are read once, then only the bytes appended since the last pass.
final class Usage: ObservableObject {
    struct Total: Equatable {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        /// US dollars at API list prices.
        var cost: Double = 0
        /// Some tokens came from a model without a known price: the cost is a lower bound.
        var unpriced = false
        var tokens: Int { input + output + cacheRead + cacheWrite }

        static func += (a: inout Total, b: Total) {
            a.input += b.input; a.output += b.output; a.cacheRead += b.cacheRead; a.cacheWrite += b.cacheWrite
            a.cost += b.cost; a.unpriced = a.unpriced || b.unpriced
        }
    }

    /// Claude, since local midnight.
    @Published private(set) var today = Total()
    /// Claude, whole session (subagents included), by Claude's session id.
    @Published private(set) var sessions: [String: Total] = [:]

    private struct FileState {
        var offset: UInt64 = 0
        var seen = Set<String>()
    }
    private let queue = DispatchQueue(label: "nook.usage", qos: .utility)
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var files: [String: FileState] = [:]
    private var bySession: [String: Total] = [:]
    private var todayTotal = Total()
    private var day = Calendar.current.startOfDay(for: Date())
    private var timer: Timer?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 5
    }

    func refresh() {
        queue.async { [weak self] in self?.scan() }
    }

    private func scan() {
        let midnight = Calendar.current.startOfDay(for: Date())
        if midnight != day { day = midnight; todayTotal = Total() }
        // Files changed today: older ones cannot add to today, and their sessions are long gone from Nook.
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        var changed = false
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= midnight,
                  let size = values.fileSize else { continue }
            var state = files[url.path] ?? FileState()
            if UInt64(size) < state.offset { state = FileState() }   // rewritten: read again
            guard UInt64(size) > state.offset else { continue }
            if read(url, state: &state) { changed = true }
            files[url.path] = state
        }
        guard changed else { return }
        let today = todayTotal, sessions = bySession
        DispatchQueue.main.async {
            if self.today != today { self.today = today }
            if self.sessions != sessions { self.sessions = sessions }
        }
    }

    /// Reads whole lines after the saved offset, 4 MB at a time (transcripts reach hundreds of MB).
    /// True when a total changed.
    private func read(_ url: URL, state: inout FileState) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        var changed = false
        var carry = Data()
        while true {
            let chunk = autoreleasepool { (try? handle.read(upToCount: 4 << 20)) ?? Data() }
            guard !chunk.isEmpty else { break }
            var data = carry
            data.append(chunk)
            // Only up to the last newline: the rest (a line still being written) waits for the next chunk or pass.
            guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else {
                carry = data
                // One line longer than 64 MB is not a usage record: skip it.
                if carry.count > 64 << 20 { state.offset += UInt64(carry.count); carry = Data() }
                continue
            }
            state.offset += UInt64(end - data.startIndex + 1)
            if lines(data[data.startIndex...end], state: &state) { changed = true }
            carry = Data(data[(end + 1)...])
        }
        return changed
    }

    private func lines(_ data: Data, state: inout FileState) -> Bool {
        let marker = Data("\"output_tokens\"".utf8)
        var changed = false
        var start = data.startIndex
        while start < data.endIndex {
            let stop = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let line = data[start..<stop]
            start = stop + 1
            guard line.range(of: marker) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String, model != "<synthetic>" else { continue }
            // The same reply is written once per content block: count it once.
            let id = "\(message["id"] as? String ?? ""):\(object["requestId"] as? String ?? "")"
            if id != ":" { guard state.seen.insert(id).inserted else { continue } }
            let total = Self.total(usage, model: model)
            if let session = object["sessionId"] as? String { bySession[session, default: Total()] += total }
            if let stamp = object["timestamp"] as? String, let date = iso.date(from: stamp), date >= day { todayTotal += total }
            changed = true
        }
        return changed
    }

    /// The whole session of a Claude agent in Nook's list; nil for Codex or before its first reply.
    func total(for session: AgentHub.Session) -> Total? {
        guard session.provider == .claude else { return nil }
        return sessions[String(session.id.dropFirst("claude:".count))]
    }

    // MARK: Prices

    /// API list prices in USD per million tokens (claude-api skill, cached 2026-10-06): input, output, cache read.
    /// Cache writes cost 1.25× input (5 min) or 2× input (1 h). First match wins, so longer names come first.
    private static let prices: [(match: String, input: Double, output: Double, read: Double)] = [
        ("fable-5-1", 10, 50, 0.25), ("mythos-5-1", 10, 50, 0.25), ("fable-5", 10, 50, 1), ("mythos-5", 10, 50, 1),
        ("opus-5-5", 4, 20, 0.2), ("opus-5", 5, 25, 0.5),
        ("opus-4-8", 5, 25, 0.5), ("opus-4-7", 5, 25, 0.5), ("opus-4-6", 5, 25, 0.5), ("opus-4-5", 5, 25, 0.5),
        ("opus-4", 15, 75, 1.5),
        ("sonnet-5-5", 2, 10, 0.2), ("sonnet-5", 2, 10, 0.2), ("sonnet-4", 3, 15, 0.3),
        ("haiku-5-5", 0.1, 0.5, 0.01), ("haiku-4-5", 1, 5, 0.1), ("haiku-3-5", 0.8, 4, 0.08),
    ]

    static func total(_ usage: [String: Any], model: String) -> Total {
        func int(_ key: String, in dict: [String: Any] = usage) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        var t = Total(input: int("input_tokens"), output: int("output_tokens"),
                      cacheRead: int("cache_read_input_tokens"), cacheWrite: int("cache_creation_input_tokens"))
        guard let price = prices.first(where: { model.contains($0.match) }) else { t.unpriced = true; return t }
        var input = price.input, output = price.output
        // Claude Haiku 5.5 costs more for prompts over 100K tokens.
        if price.match == "haiku-5-5" && t.input + t.cacheRead + t.cacheWrite > 100_000 { input = 0.5; output = 2.5 }
        let split = usage["cache_creation"] as? [String: Any]
        let hour = split.map { int("ephemeral_1h_input_tokens", in: $0) } ?? 0
        let writes = Double(t.cacheWrite - hour) * input * 1.25 + Double(hour) * input * 2
        var cost = (Double(t.input) * input + Double(t.output) * output + Double(t.cacheRead) * price.read + writes) / 1_000_000
        if usage["speed"] as? String == "fast" { cost *= 2 }
        t.cost = cost
        return t
    }
}
