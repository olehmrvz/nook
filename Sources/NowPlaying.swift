import AppKit

/// Spotify and Apple Music through AppleScript. Players are only queried while they run,
/// so Nook never launches them by itself.
final class NowPlaying: ObservableObject {
    enum Player: String {
        case spotify = "Spotify"
        case music = "Music"
        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
    }

    @Published private(set) var player: Player?
    @Published private(set) var isPlaying = false
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var positionDate = Date()

    private var artworkURL = ""
    private var timer: Timer?

    var hasTrack: Bool { player != nil && !title.isEmpty }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Position extrapolated between polls so the progress bar moves smoothly.
    func livePosition(at date: Date) -> Double {
        guard isPlaying else { return position }
        return min(duration, position + date.timeIntervalSince(positionDate))
    }

    private func running(_ p: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).isEmpty
    }

    /// AppleScript runs on its own serial queue: the first call may wait on the Automation prompt.
    private let queue = DispatchQueue(label: "nook.nowplaying")
    private var inFlight = false

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let candidates = [Player.spotify, .music].filter(running)
        queue.async { [weak self] in
            guard let self else { return }
            var best: (Player, [String])?
            for p in candidates {
                guard let fields = self.query(p) else { continue }
                if fields[0] == "playing" { best = (p, fields); break }
                if best == nil, fields.count >= 6 { best = (p, fields) }
            }
            DispatchQueue.main.async {
                self.inFlight = false
                self.apply(best)
            }
        }
    }

    private func apply(_ best: (Player, [String])?) {
        guard let (p, f) = best, f.count >= 6 else {
            if player != nil { player = nil; isPlaying = false; title = ""; artist = ""; artwork = nil }
            return
        }
        player = p
        isPlaying = f[0] == "playing"
        title = f[1]
        artist = f[2]
        duration = Self.number(f[4]) / 1000
        position = Self.number(f[5])
        positionDate = Date()
        if f[3] != artworkURL {
            artworkURL = f[3]
            loadArtwork(p)
        }
    }

    private func query(_ p: Player) -> [String]? {
        let source: String
        switch p {
        case .spotify:
            source = """
            tell application "Spotify"
              set st to player state as string
              if st is "stopped" then return "stopped"
              set t to current track
              return st & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (artwork url of t) & linefeed & (duration of t) & linefeed & (player position)
            end tell
            """
        case .music:
            source = """
            tell application "Music"
              set st to player state as string
              if st is "stopped" then return "stopped"
              set t to current track
              return st & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (name of t) & (album of t) & linefeed & ((duration of t) * 1000) & linefeed & (player position)
            end tell
            """
        }
        var error: NSDictionary?
        guard let out = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else { return nil }
        return out.components(separatedBy: "\n")
    }

    private static func number(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
    }

    private func loadArtwork(_ p: Player) {
        artwork = nil
        if p == .music {
            // Music exposes raw artwork data; fetch it once per track.
            let expected = artworkURL
            queue.async { [weak self] in
                let script = "tell application \"Music\" to get raw data of artwork 1 of current track"
                var error: NSDictionary?
                let data = NSAppleScript(source: script)?.executeAndReturnError(&error).data
                DispatchQueue.main.async {
                    if self?.artworkURL == expected { self?.artwork = data.flatMap(NSImage.init(data:)) }
                }
            }
            return
        }
        guard let url = URL(string: artworkURL), url.scheme == "https" else { return }
        let expected = artworkURL
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                if self?.artworkURL == expected { self?.artwork = image }
            }
        }.resume()
    }

    // MARK: Controls

    func playPause() { send("playpause"); isPlaying.toggle(); positionDate = Date() }
    func next() { send("next track"); after { self.refresh() } }
    func previous() { send("previous track"); after { self.refresh() } }

    func seek(to seconds: Double) {
        send("set player position to \(Int(seconds))")
        position = seconds
        positionDate = Date()
    }

    func openPlayer() {
        guard let player,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func send(_ command: String) {
        guard let player else { return }
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"\(player.rawValue)\" to \(command)")?.executeAndReturnError(&error)
        }
    }

    private func after(_ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: block)
    }
}
