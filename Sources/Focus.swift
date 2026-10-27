import Foundation

/// Do Not Disturb and other Focus modes. macOS keeps their state in ~/Library/DoNotDisturb/DB, readable only
/// with Full Disk Access (the same access notification islands need). Nook watches that folder (no polling)
/// and reports when a Focus turns on or off.
final class FocusWatcher {
    /// On the main thread: Focus on/off, its name and SF Symbol.
    var onChange: ((Bool, String, String) -> Void)?
    /// False when the folder cannot be read (no Full Disk Access).
    private(set) var available = false

    private let queue = DispatchQueue(label: "nook.focus")
    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var last: String?
    private let logURL = supportDir.appendingPathComponent("focus-debug.log")

    private var retry: DispatchSourceTimer?

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.watch()
            // Full Disk Access may be granted later: look again every 5 minutes until the folder opens.
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 300, repeating: 300, leeway: .seconds(30))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                if self.available { self.retry?.cancel(); self.retry = nil } else { self.watch() }
            }
            timer.resume()
            self.retry = timer
        }
    }

    private func watch() {
        sources.forEach { $0.cancel() }
        sources = []
        // The folder catches files replaced atomically, the file itself catches writes in place.
        for path in [folder.path, folder.appendingPathComponent("Assertions.json").path] {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                                   queue: queue)
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        available = !sources.isEmpty
        last = state()?.key   // the state at launch is not news
    }

    /// Several writes come together: read once they settle, and re-attach to a replaced file.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let previous = self.last
            self.watch()
            self.last = previous
            guard let now = self.state(), now.key != self.last else { return }
            self.last = now.key
            DispatchQueue.main.async { self.onChange?(now.on, now.name, now.symbol) }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Active assertion → its mode's name and symbol from ModeConfigurations.json.
    private func state() -> (on: Bool, name: String, symbol: String, key: String)? {
        guard let assertions = json("Assertions.json") else { return nil }
        let records = (assertions["data"] as? [[String: Any]] ?? []).flatMap { $0["storeAssertionRecords"] as? [[String: Any]] ?? [] }
        let mode = records.compactMap { ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String }.first
        log("records=\(records.count) mode=\(mode ?? "-") keys=\(assertions.keys.sorted())")
        guard let mode else { return (false, Self.defaultName, "moon.fill", "off") }
        var name = Self.defaultName, symbol = "moon.fill"
        if let configs = json("ModeConfigurations.json"),
           let all = (configs["data"] as? [[String: Any]])?.first?["modeConfigurations"] as? [String: Any],
           let entry = (all[mode] as? [String: Any])?["mode"] as? [String: Any] {
            if let n = entry["name"] as? String, !n.isEmpty, mode != "com.apple.donotdisturb.mode.default" { name = n }
            if let s = entry["symbolImageName"] as? String, !s.isEmpty { symbol = s }
        }
        return (true, name, symbol, "on:\(mode)")
    }

    private static let defaultName = "Не беспокоить"

    private func json(_ file: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Structure only (counts, mode ids, key names), first 30 lines: to check the format on new macOS versions.
    private func log(_ text: String) {
        let lines = (try? String(contentsOf: logURL, encoding: .utf8))?.split(separator: "\n").count ?? 0
        guard lines < 30 else { return }
        let line = "\(Date()) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
    }
}
