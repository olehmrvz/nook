import AppKit
import AVFoundation
import Speech

/// Teleprompter under the camera. Scrolls at a fixed pace, or follows your voice on device.
final class Cuely: ObservableObject {
    struct Script: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var body: String
    }

    struct Line: Identifiable {
        let id: Int
        let text: String
        let firstWord: Int
    }

    @Published var scripts: [Script] = [] { didSet { save() } }
    @Published var currentID: UUID? { didSet { save() } }
    @Published var wordsPerMinute: Double = 140 { didSet { save() } }
    @Published var fontSize: Double = 24 { didSet { save() } }
    @Published var voiceFollow = false { didSet { save() } }
    @Published var language = "ru-RU" { didSet { save() } }
    @Published private(set) var isPresenting = false
    @Published private(set) var isPaused = false
    @Published private(set) var wordIndex: Double = 0
    @Published private(set) var lines: [Line] = []
    @Published private(set) var status: String?

    var onPresentChange: ((Bool) -> Void)?

    private var words: [String] = []
    private var ticker: Timer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var loading = true
    private let fileURL = supportDir.appendingPathComponent("cuely.json")

    static let languages = [("ru-RU", "Русский"), ("de-DE", "Deutsch"), ("en-US", "English"), ("uk-UA", "Українська")]

    init() {
        load()
        loading = false
        if scripts.isEmpty {
            scripts = [Script(title: "Новый сценарий", body: "Вставьте сюда текст. Nook покажет его прямо под камерой, чтобы взгляд оставался в объективе.")]
            currentID = scripts[0].id
        }
    }

    var current: Script? { scripts.first { $0.id == currentID } ?? scripts.first }

    var currentLine: Int {
        lines.lastIndex { $0.firstWord <= Int(wordIndex) } ?? 0
    }

    // MARK: Editing

    func update(body: String) {
        guard let id = current?.id, let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].body = body
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        scripts[i].title = firstLine.isEmpty ? "Без названия" : String(firstLine.prefix(40))
    }

    func newScript() {
        let script = Script(title: "Новый сценарий", body: "")
        scripts.insert(script, at: 0)
        currentID = script.id
    }

    func delete(_ script: Script) {
        scripts.removeAll { $0.id == script.id }
        if scripts.isEmpty { newScript() }
        if currentID == script.id { currentID = scripts.first?.id }
    }

    // MARK: Presenting

    func present() {
        guard let body = current?.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        buildLines(body)
        wordIndex = 0
        isPaused = false
        status = nil
        isPresenting = true
        onPresentChange?(true)
        if voiceFollow { startListening() } else { startTicker() }
    }

    func stop() {
        ticker?.invalidate()
        stopListening()
        isPresenting = false
        onPresentChange?(false)
    }

    func togglePause() {
        isPaused.toggle()
        if voiceFollow { isPaused ? stopListening() : startListening() }
    }

    func restart() { wordIndex = 0 }

    func nudge(lines delta: Int) {
        let target = min(max(0, currentLine + delta), max(0, lines.count - 1))
        if lines.indices.contains(target) { wordIndex = Double(lines[target].firstWord) }
    }

    func changeSpeed(_ delta: Double) { wordsPerMinute = min(300, max(60, wordsPerMinute + delta)) }

    private func buildLines(_ body: String) {
        var result: [Line] = []
        var all: [String] = []
        for paragraph in body.components(separatedBy: .newlines) {
            let tokens = paragraph.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.isEmpty { continue }
            var start = 0
            while start < tokens.count {
                let chunk = Array(tokens[start..<min(start + 7, tokens.count)])
                result.append(Line(id: result.count, text: chunk.joined(separator: " "), firstWord: all.count))
                all += chunk.map(Self.normalize)
                start += 7
            }
        }
        lines = result
        words = all
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, !self.isPaused else { return }
            self.wordIndex = min(Double(self.words.count), self.wordIndex + self.wordsPerMinute / 60 / 30)
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    // MARK: Voice follow

    private func startListening() {
        SFSpeechRecognizer.requestAuthorization { auth in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async {
                    guard auth == .authorized, mic else {
                        self.status = "Нет доступа к микрофону или распознаванию речи — включаю автопрокрутку"
                        self.startTicker()
                        return
                    }
                    self.beginRecognition()
                }
            }
        }
    }

    private func beginRecognition() {
        guard isPresenting, !isPaused else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            status = "Распознавание для этого языка недоступно — автопрокрутка"
            startTicker()
            return
        }
        stopListening()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            status = "Микрофон недоступен — автопрокрутка"
            startTicker()
            return
        }
        status = "Слушаю…"
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.segments.suffix(5).map { Self.normalize($0.substring) }
                DispatchQueue.main.async { self.follow(spoken) }
            }
            // Recognition sessions end after a pause or about a minute; start a fresh one.
            if error != nil || result?.isFinal == true {
                DispatchQueue.main.async {
                    if self.isPresenting && !self.isPaused && self.voiceFollow { self.beginRecognition() }
                }
            }
        }
    }

    private func stopListening() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    /// Moves the cursor to where the last spoken words best match the script ahead.
    private func follow(_ spoken: [String]) {
        let tail = spoken.filter { !$0.isEmpty }
        guard let last = tail.last, !words.isEmpty else { return }
        let cursor = Int(wordIndex)
        let lower = max(0, cursor - 4)
        let upper = min(words.count - 1, cursor + 25)
        guard lower <= upper else { return }
        var best: (index: Int, score: Int)?
        for j in lower...upper where words[j] == last {
            var score = 1
            for k in 1..<tail.count where j - k >= 0 && words[j - k] == tail[tail.count - 1 - k] { score += 1 }
            // Prefer the nearest strong match ahead of the cursor.
            if best == nil || score > best!.score { best = (j, score) }
        }
        if let best, best.score >= (tail.count >= 3 ? 2 : 1), best.index + 1 >= cursor - 1 {
            wordIndex = Double(best.index + 1)
        }
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Storage

    private struct Stored: Codable {
        var scripts: [Script]
        var currentID: UUID?
        var wpm: Double
        var fontSize: Double
        var voiceFollow: Bool
        var language: String
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL), let s = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        scripts = s.scripts
        currentID = s.currentID
        wordsPerMinute = s.wpm
        fontSize = s.fontSize
        voiceFollow = s.voiceFollow
        language = s.language
    }

    /// Debounced and written off the main thread: typing or dragging a slider no longer writes on every change.
    private func save() {
        guard !loading else { return }
        saveWork?.cancel()
        let s = Stored(scripts: scripts, currentID: currentID, wpm: wordsPerMinute, fontSize: fontSize,
                       voiceFollow: voiceFollow, language: language)
        let url = fileURL
        let work = DispatchWorkItem {
            DispatchQueue.global(qos: .utility).async {
                if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: [.atomic]) }
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
    private var saveWork: DispatchWorkItem?
}
