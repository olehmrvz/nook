import AppKit
import Carbon.HIToolbox
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Where answers come from.
enum AIProvider: String, CaseIterable, Identifiable {
    /// The person's Claude Code login (subscription), through `claude -p`: no key needed.
    case claudeCode
    /// An Anthropic API key, kept in the keychain.
    case anthropic
    /// Apple's on-device model (macOS 26 with Apple Intelligence).
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: L("Claude Code (ваша подписка)")
        case .anthropic: L("Claude API (свой ключ)")
        case .apple: L("Apple Intelligence (на этом Mac)")
        }
    }
}

extension Settings {
    static var aiProvider: AIProvider {
        get { AIProvider(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? (Assistant.claudeBinary != nil ? .claudeCode : .anthropic) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "aiProvider") }
    }
    /// For the API key route.
    static var aiModel: String {
        get { UserDefaults.standard.string(forKey: "aiModel") ?? "claude-opus-5-5" }
        set { UserDefaults.standard.set(newValue, forKey: "aiModel") }
    }
}

/// Actions on the selected text in any app. Most replace the selection; a summary is shown in the notch.
enum AIAction: String, CaseIterable {
    case fix, rewrite, shorter, summarize, toEnglish, toRussian

    var title: String {
        switch self {
        case .fix: L("Исправить ошибки в выделенном")
        case .rewrite: L("Переписать выделенное понятнее")
        case .shorter: L("Сократить выделенное")
        case .summarize: L("Кратко пересказать выделенное")
        case .toEnglish: L("Перевести выделенное на английский")
        case .toRussian: L("Перевести выделенное на русский")
        }
    }

    var english: String {
        switch self {
        case .fix: "fix grammar spelling"
        case .rewrite: "rewrite improve writing"
        case .shorter: "make shorter"
        case .summarize: "summarize"
        case .toEnglish: "translate to english"
        case .toRussian: "translate to russian"
        }
    }

    var symbol: String {
        switch self {
        case .fix: "checkmark.seal.fill"
        case .rewrite: "pencil.and.outline"
        case .shorter: "text.badge.minus"
        case .summarize: "text.alignleft"
        case .toEnglish, .toRussian: "character.bubble.fill"
        }
    }

    /// The selection is replaced by the answer (a summary is shown instead).
    var replaces: Bool { self != .summarize }

    var instruction: String {
        let only = "Reply with the resulting text only: no preface, no quotes, no comments, no Markdown unless the input uses it."
        switch self {
        case .fix: return "Fix spelling, grammar and punctuation of the text. Keep its language, meaning, tone and formatting. \(only)"
        case .rewrite: return "Rewrite the text so it reads clearly and naturally. Keep its language, meaning and formatting. \(only)"
        case .shorter: return "Make the text noticeably shorter while keeping every important point. Keep its language. \(only)"
        case .summarize: return "Summarize the text in a few short sentences in the language of the text. Reply with the summary only."
        case .toEnglish: return "Translate the text into English. Keep formatting. \(only)"
        case .toRussian: return "Translate the text into Russian. Keep formatting. \(only)"
        }
    }
}

/// One request at a time to the chosen model, streamed: the notch shows the answer as it grows.
final class Assistant: ObservableObject {
    @Published private(set) var working = false
    @Published private(set) var question = ""
    @Published private(set) var answer = ""
    @Published private(set) var failure: String?

    private var request: Task<Void, Never>?
    private var process: Process?

    /// `claude` from its usual install places (a GUI app has no shell PATH).
    static var claudeBinary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    var isReady: Bool {
        switch Settings.aiProvider {
        case .claudeCode: Self.claudeBinary != nil
        case .anthropic: Keychain.exists("anthropic")
        case .apple: Self.appleStatus == nil
        }
    }

    /// nil when Apple's model can answer; otherwise why not.
    static var appleStatus: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return L("Этот Mac не поддерживает Apple Intelligence")
                case .appleIntelligenceNotEnabled: return L("Включите Apple Intelligence в Системных настройках")
                case .modelNotReady: return L("Модель Apple ещё загружается")
                @unknown default: return L("Модель Apple недоступна")
                }
            }
        }
        #endif
        return L("Нужна macOS 26")
    }

    /// `effort` "low" for simple rewrites; nil keeps the model's default.
    func ask(_ prompt: String, title: String? = nil, system: String? = nil, effort: String? = nil,
             done: ((Result<String, Error>) -> Void)? = nil) {
        cancel()
        question = title ?? prompt
        answer = ""
        failure = nil
        working = true
        let finish: (Result<String, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                if case .failure(let error) = result { self.failure = error.localizedDescription }
                done?(result)
            }
        }
        let append: (String) -> Void = { [weak self] piece in DispatchQueue.main.async { self?.answer += piece } }
        switch Settings.aiProvider {
        case .claudeCode: runClaudeCode(prompt, system: system, effort: effort, append: append, finish: finish)
        case .anthropic:
            request = Task { await self.runAPI(prompt, system: system, effort: effort, append: append, finish: finish) }
        case .apple:
            request = Task { await self.runApple(prompt, system: system, append: append, finish: finish) }
        }
    }

    func cancel() {
        request?.cancel()
        request = nil
        process?.terminate()
        process = nil
        if working { working = false }
    }

    func clear() {
        cancel()
        question = ""
        answer = ""
        failure = nil
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Claude Code

    /// `claude -p` without the user's settings (so no hooks: the call never shows up as an agent session in the
    /// notch), no tools, nothing saved. The text goes in on stdin, not in the arguments other processes can read.
    private func runClaudeCode(_ prompt: String, system: String?, effort: String?,
                               append: @escaping (String) -> Void, finish: @escaping (Result<String, Error>) -> Void) {
        guard let binary = Self.claudeBinary else { return finish(.failure(Failure(message: L("Claude Code не найден")))) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var arguments = ["-p", "--setting-sources", "project", "--no-session-persistence", "--tools", "",
                         "--output-format", "stream-json", "--include-partial-messages", "--verbose"]
        if let system { arguments += ["--append-system-prompt", system] }
        if let effort { arguments += ["--effort", effort] }
        process.arguments = arguments
        process.currentDirectoryURL = supportDir
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var buffer = Data()
        var text = ""
        var resultError: String?
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if json["type"] as? String == "stream_event", let event = json["event"] as? [String: Any],
                   event["type"] as? String == "content_block_delta", let delta = event["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta", let piece = delta["text"] as? String {
                    text += piece
                    append(piece)
                } else if json["type"] as? String == "result", json["is_error"] as? Bool == true {
                    resultError = json["result"] as? String ?? L("Claude Code не ответил")
                }
            }
        }
        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            if let resultError { return finish(.failure(Failure(message: resultError))) }
            if finished.terminationStatus != 0 && text.isEmpty {
                return finish(.failure(Failure(message: L("Claude Code завершился с кодом \(finished.terminationStatus)"))))
            }
            finish(.success(text))
        }
        do {
            try process.run()
        } catch {
            return finish(.failure(error))
        }
        self.process = process
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
    }

    // MARK: Claude API

    /// The Messages API, streamed (server-sent events). Fallback on a refusal is on (`fallbacks: "default"`).
    private func runAPI(_ prompt: String, system: String?, effort: String?,
                        append: @escaping (String) -> Void, finish: @escaping (Result<String, Error>) -> Void) async {
        guard let key = Keychain.read("anthropic") else { return finish(.failure(Failure(message: L("Нет ключа Claude API")))) }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        var body: [String: Any] = [
            "model": Settings.aiModel, "max_tokens": 64000, "stream": true, "fallbacks": "default",
            "messages": [["role": "user", "content": prompt]],
        ]
        if let system { body["system"] = system }
        if let effort { body["output_config"] = ["effort": effort] }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var text = ""
            var errorBody = ""
            for try await line in bytes.lines {
                if status != 200 { errorBody += line; continue }
                guard line.hasPrefix("data:") else { continue }
                let data = Data(line.dropFirst(5).utf8)
                guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "content_block_delta":
                    if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                       let piece = delta["text"] as? String {
                        text += piece
                        append(piece)
                    }
                case "message_delta":
                    if (event["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                        return finish(.failure(Failure(message: L("Модель отказалась отвечать на этот запрос"))))
                    }
                case "error":
                    let message = (event["error"] as? [String: Any])?["message"] as? String ?? L("Ошибка Claude API")
                    return finish(.failure(Failure(message: message)))
                default: break
                }
            }
            if status != 200 {
                let json = try? JSONSerialization.jsonObject(with: Data(errorBody.utf8)) as? [String: Any]
                let message = (json?["error"] as? [String: Any])?["message"] as? String ?? L("Claude API: код \(status)")
                return finish(.failure(Failure(message: status == 401 ? L("Ключ Claude API не подошёл") : message)))
            }
            finish(.success(text))
        } catch is CancellationError {
            finish(.failure(Failure(message: L("Отменено"))))
        } catch {
            finish(.failure(error))
        }
    }

    // MARK: Apple

    private func runApple(_ prompt: String, system: String?, append: @escaping (String) -> Void,
                          finish: @escaping (Result<String, Error>) -> Void) async {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), Self.appleStatus == nil {
            let session = LanguageModelSession(instructions: system ?? "Answer briefly, in the language of the question.")
            do {
                var shown = ""
                for try await snapshot in session.streamResponse(to: prompt) {
                    let text = snapshot.content
                    if text.hasPrefix(shown) { append(String(text.dropFirst(shown.count))) }
                    shown = text
                }
                return finish(.success(shown))
            } catch {
                return finish(.failure(error))
            }
        }
        #endif
        finish(.failure(Failure(message: Self.appleStatus ?? L("Модель Apple недоступна"))))
    }
}

/// The selected text of the app in front: Accessibility first, then a borrowed ⌘C (the clipboard comes back).
enum Selection {
    static func read(_ done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.3)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                var selected: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
                   let text = selected as? String, !text.isEmpty {
                    return DispatchQueue.main.async { done(text) }
                }
            }
            DispatchQueue.main.async { copySelection(done) }
        }
    }

    /// ⌘C into a clipboard Nook gives back afterwards; accepted only if the clipboard really changed.
    private static func copySelection(_ done: @escaping (String?) -> Void) {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        let before = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: TextInsertion.tag)
            event?.post(tap: .cghidEventTap)
        }
        // A busy app (Electron, a loaded browser) can take more than a moment to copy: wait up to a second, or the
        // copy lands later and replaces the clipboard for good.
        func check(after waited: Double) {
            guard board.changeCount != before else {
                if waited >= 1 { return done(nil) }
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check(after: waited + 0.05) }
            }
            let text = board.string(forType: .string)
            let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
            saved.forEach { $0.setData(Data(), forType: transient) }
            board.clearContents()
            if !saved.isEmpty { board.writeObjects(saved) }
            done(text?.isEmpty == false ? text : nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check(after: 0.05) }
    }
}

/// API keys in the login keychain, readable only by Nook.
enum Keychain {
    private static let service = "dev.nook.app.ai"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Whether a key is saved, without decrypting it: safe on the main thread. Reading the secret can show the
    /// keychain's "Nook wants to use your confidential information" dialog (after a signature change) and block.
    static func exists(_ account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ value: String?, for account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(item as CFDictionary, nil)
    }
}
