import AppKit

extension Settings {
    private static var defaults: UserDefaults { .standard }

    /// [name, link with {query}]: "yt котики" opens YouTube's search for котики.
    static var quicklinks: [[String]] {
        get {
            defaults.array(forKey: "quicklinks") as? [[String]] ?? [
                ["yt", "https://www.youtube.com/results?search_query={query}"],
                ["maps", "https://www.google.com/maps/search/{query}"],
                ["translate", "https://translate.google.com/?sl=auto&tl=ru&text={query}"],
                ["gh", "https://github.com/search?q={query}"],
            ]
        }
        set { defaults.set(newValue, forKey: "quicklinks") }
    }
    /// [name, shell text]: run with /bin/zsh -lc from the home folder.
    static var customCommands: [[String]] {
        get { defaults.array(forKey: "customCommands") as? [[String]] ?? [] }
        set { defaults.set(newValue, forKey: "customCommands") }
    }
    static var launcherFiles: Bool {
        get { defaults.object(forKey: "launcherFiles") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcherFiles") }
    }
    /// Menu items of the app in front, and open windows, in the search.
    static var launcherMenus: Bool {
        get { defaults.object(forKey: "launcherMenus") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcherMenus") }
    }
    static var launcherOpenWindows: Bool {
        get { defaults.object(forKey: "launcherOpenWindows") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcherOpenWindows") }
    }
    static var launcherShortcuts: Bool {
        get { defaults.object(forKey: "launcherShortcuts") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "launcherShortcuts") }
    }
}

/// Apple Shortcuts through the `shortcuts` tool (no permission needed).
enum AppleShortcuts {
    /// "Name (UUID)" lines; nothing on failure. Off the main thread.
    static func list() -> [(name: String, id: String)] {
        guard let output = run(["list", "--show-identifiers"], wait: 5) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            guard line.hasSuffix(")"), let open = line.range(of: " (", options: .backwards) else { return nil }
            let id = line[open.upperBound..<line.index(before: line.endIndex)]
            guard id.count == 36 else { return nil }
            return (String(line[..<open.lowerBound]), String(id))
        }
    }

    static func run(_ id: String) {
        DispatchQueue.global(qos: .userInitiated).async { _ = run(["run", id], wait: nil) }
    }

    @discardableResult
    private static func run(_ arguments: [String], wait seconds: Double?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        guard let seconds else { return nil }
        // Reading waits for the end of the output: a hung tool is stopped after `seconds`.
        let stopper = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: stopper)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        stopper.cancel()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The person's own shell commands, run like in a terminal (`zsh -lc`), never with values spliced into the text.
enum CustomCommands {
    /// On the main thread: the last line of the output, or the error.
    static func run(name: String, script: String, done: @escaping (_ ok: Bool, _ text: String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            var environment = ProcessInfo.processInfo.environment
            environment["NOOK"] = "1"
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch {
                DispatchQueue.main.async { done(false, error.localizedDescription) }
                return
            }
            let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errors = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            let last = (ok ? output : (errors.isEmpty ? output : errors))
                .split(separator: "\n").last.map(String.init) ?? (ok ? L("Готово") : L("Код \(process.terminationStatus)"))
            DispatchQueue.main.async { done(ok, String(last.prefix(200))) }
        }
    }
}

/// Files by name through Spotlight (no Full Disk Access): the five best, from three characters.
final class FileSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var work: DispatchWorkItem?
    /// On the main thread.
    var onResults: (([URL]) -> Void)?

    func search(_ text: String) {
        work?.cancel()
        stop()
        guard text.count >= 3, Settings.launcherFiles else { onResults?([]); return }
        // A short pause: no Spotlight query per keystroke.
        let work = DispatchWorkItem { [weak self] in self?.start(text) }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func start(_ text: String) {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(text)*")
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                                          queue: .main) { [weak self, weak query] _ in
            guard let self, let query else { return }
            query.disableUpdates()
            var urls: [URL] = []
            for index in 0..<min(query.resultCount, 40) {
                guard let item = query.result(at: index) as? NSMetadataItem,
                      let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                // Apps come from the app index; caches and libraries are noise.
                if path.hasSuffix(".app") || path.contains("/Library/") || path.contains("/.") { continue }
                urls.append(URL(fileURLWithPath: path))
                if urls.count == 5 { break }
            }
            self.stop()
            self.onResults?(urls)
        }
        self.query = query
        query.start()
    }

    func stop() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// Emoji by name in the system language and in English (":сердце", ":heart"), from macOS's own emoji names.
enum Emoji {
    struct Entry {
        let character: String
        let title: String
        /// Folded words of every name.
        let words: [String]
    }

    private static let resources = "/System/Library/PrivateFrameworks/CoreEmoji.framework/Versions/A/Resources"

    /// Off the main thread (reads two string tables of a few hundred kilobytes).
    static func load() -> [Entry] {
        func names(_ language: String) -> [String: String] {
            NSDictionary(contentsOfFile: "\(resources)/\(language).lproj/AppleName.strings") as? [String: String] ?? [:]
        }
        let language = Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
        let local = names(language), english = language == "en" ? [:] : names("en")
        var entries: [Entry] = []
        if local.isEmpty && english.isEmpty {
            // Older systems without the table: Unicode names.
            for range: ClosedRange<UInt32> in [0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1FAFF, 0x2600...0x27BF] {
                for value in range {
                    guard let scalar = Unicode.Scalar(value), scalar.properties.isEmoji, let name = scalar.properties.name else { continue }
                    let character = String(scalar) + (scalar.properties.isEmojiPresentation ? "" : "\u{FE0F}")
                    entries.append(Entry(character: character, title: name.capitalized, words: words(name)))
                }
            }
            return entries
        }
        for character in Set(local.keys).union(english.keys) {
            let title = local[character] ?? english[character] ?? ""
            let all = [local[character], english[character]].compactMap { $0 }.flatMap(words)
            entries.append(Entry(character: character, title: title.prefix(1).uppercased() + title.dropFirst(), words: all))
        }
        // The table has no order: by code point, so faces come first like in the system picker.
        return entries.sorted { $0.character.unicodeScalars.first!.value < $1.character.unicodeScalars.first!.value }
    }

    private static func words(_ name: String) -> [String] {
        name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { Launcher.fold(String($0)) }
    }

    /// Every typed word starts some word of a name; whole words and short names first ("кот" → 🐈 before a flag).
    static func search(_ text: String, in entries: [Entry]) -> [Entry] {
        let typed = text.split(separator: " ").map { Launcher.fold(String($0)) }
        guard !typed.isEmpty else { return Array(entries.prefix(30)) }
        var scored: [(Entry, Int)] = []
        for entry in entries {
            var score = 0
            for word in typed {
                if entry.words.contains(word) { score += 3 } else if entry.words.contains(where: { $0.hasPrefix(word) }) { score += 1 } else { score = -1; break }
            }
            if score > 0 { scored.append((entry, score * 100 - entry.words.count)) }
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
