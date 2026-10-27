import AppKit
import SwiftUI

/// What plays on the Mac, from any app (Spotify, Music, a browser tab, podcasts).
/// The system Now Playing comes through a small bridge running inside Apple's perl, because macOS 15.4+
/// answers MediaRemote only to Apple-signed processes. Without the bridge, AppleScript covers Spotify and Music.
final class NowPlaying: ObservableObject {
    struct Source: Equatable {
        var name: String
        var bundleID: String?
        var pid: Int32
    }

    /// Players the AppleScript fallback knows.
    enum Player: String {
        case spotify = "Spotify"
        case music = "Music"
        var bundleID: String { self == .spotify ? "com.spotify.client" : "com.apple.Music" }
        var title: String { self == .spotify ? "Spotify" : "Музыка" }
    }

    @Published private(set) var source: Source?
    @Published private(set) var isPlaying = false
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artwork: NSImage?
    /// Two colours taken from the artwork for the ambient glow; empty until known.
    @Published private(set) var glow: [Color] = []
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var positionDate = Date()
    private var rate: Double = 1

    var hasTrack: Bool { source != nil && !title.isEmpty }
    var glowColors: [Color] { glow.count == 2 ? glow : Palette.musicGlow }

    /// Brand colour of the playing app for the small dot next to its name.
    var sourceColor: Color {
        switch source?.bundleID {
        case Player.spotify.bundleID: return Palette.spotify
        case Player.music.bundleID: return Palette.music
        default: return Color.white.opacity(0.6)
        }
    }

    var sourceIcon: NSImage? { source.flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon } }

    func start() {
        if !startBridge() { startAppleScript() }
    }

    /// Position extrapolated from the last report so the progress bar moves smoothly.
    func livePosition(at date: Date) -> Double {
        guard isPlaying else { return position }
        let speed = rate > 0 ? rate : 1
        return min(duration, max(0, position + date.timeIntervalSince(positionDate) * speed))
    }

    // MARK: System Now Playing bridge

    private var bridge: Process?
    private var bridgeInput: FileHandle?
    private var buffer = Data()
    private var bridgeFailures = 0
    private var bridgeStarted = Date()

    private var bridgeFiles: (script: String, library: String)? {
        guard let resources = Bundle.main.resourceURL?.path else { return nil }
        let script = resources + "/nook-media.pl", library = resources + "/libNookMediaRemote.dylib"
        let fm = FileManager.default
        guard fm.fileExists(atPath: script), fm.fileExists(atPath: library), fm.isExecutableFile(atPath: "/usr/bin/perl") else { return nil }
        return (script, library)
    }

    private func startBridge() -> Bool {
        guard let files = bridgeFiles else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [files.script, files.library]
        // No inherited PERL5OPT / PERL5LIB / DYLD_*: perl loads only our bridge.
        process.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.bridgeEnded() }
        }
        do { try process.run() } catch { return false }
        bridgeStarted = Date()
        bridge = process
        bridgeInput = input.fileHandleForWriting
        return true
    }

    private func bridgeEnded() {
        bridge = nil
        bridgeInput = nil
        buffer.removeAll()
        // A bridge that ran for a minute was healthy; only quick crashes count towards giving up.
        bridgeFailures = Date().timeIntervalSince(bridgeStarted) > 60 ? 1 : bridgeFailures + 1
        // A crash or a macOS change that breaks the bridge: retry a few times, then fall back.
        if bridgeFailures <= 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 * Double(bridgeFailures)) { [weak self] in
                guard let self, !self.startBridge() else { return }
                self.startAppleScript()
            }
        } else {
            startAppleScript()
        }
    }

    private func receive(_ data: Data) {
        // Only the new chunk can hold the line end: no rescanning megabytes of cover art on every read.
        guard data.contains(UInt8(ascii: "\n")) else { buffer.append(data); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(json) }
        }
    }

    /// Assigns only real changes, so a repeated report does not redraw the notch.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<NowPlaying, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    private func apply(_ json: [String: Any]) {
        if json["ready"] != nil { return }
        let pid = Int32(json["pid"] as? Int ?? 0)
        let newTitle = json["title"] as? String ?? ""
        guard pid > 0, !newTitle.isEmpty else { clear(); return }
        let newArtist = json["artist"] as? String ?? ""
        let trackChanged = newTitle != title || newArtist != artist
        if source?.pid != pid {
            let app = NSRunningApplication(processIdentifier: pid)
            source = Source(name: app?.localizedName ?? "Плеер", bundleID: app?.bundleIdentifier, pid: pid)
        }
        set(\.title, newTitle)
        set(\.artist, newArtist)
        set(\.album, json["album"] as? String ?? "")
        set(\.duration, json["duration"] as? Double ?? 0)
        rate = json["rate"] as? Double ?? 0
        set(\.isPlaying, json["playing"] as? Bool ?? (rate > 0))
        set(\.position, json["elapsed"] as? Double ?? 0)
        let stamp = json["timestamp"] as? Double ?? 0
        set(\.positionDate, stamp > 0 ? Date(timeIntervalSince1970: stamp) : Date())
        if let encoded = json["artwork"] as? String, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
            setArtwork(image)
        } else if trackChanged {
            artwork = nil
        }
    }

    private func clear() {
        guard source != nil else { return }
        source = nil; isPlaying = false; title = ""; artist = ""; album = ""
        setArtwork(nil)
    }

    private func command(_ line: String) -> Bool {
        guard let bridgeInput, let data = (line + "\n").data(using: .utf8) else { return false }
        do { try bridgeInput.write(contentsOf: data) } catch { return false }
        return true
    }

    // MARK: AppleScript fallback (Spotify and Music only)

    /// AppleScript runs on its own serial queue: the first call may wait on the Automation prompt.
    private let queue = DispatchQueue(label: "nook.nowplaying")
    private var inFlight = false
    private var timer: Timer?
    private var player: Player?
    private var artworkURL = ""

    private func startAppleScript() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func running(_ p: Player) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).isEmpty
    }

    private func refresh() {
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
                self.applyScript(best)
            }
        }
    }

    private func applyScript(_ best: (Player, [String])?) {
        guard let (p, f) = best, f.count >= 6 else {
            player = nil
            clear()
            return
        }
        player = p
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: p.bundleID).first?.processIdentifier ?? 0
        source = Source(name: p.title, bundleID: p.bundleID, pid: pid)
        isPlaying = f[0] == "playing"
        title = f[1]
        artist = f[2]
        duration = Self.number(f[4]) / 1000
        position = Self.number(f[5])
        positionDate = Date()
        rate = isPlaying ? 1 : 0
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
                    if self?.artworkURL == expected { self?.setArtwork(data.flatMap(NSImage.init(data:))) }
                }
            }
            return
        }
        guard let url = URL(string: artworkURL), url.scheme == "https" else { return }
        let expected = artworkURL
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                if self?.artworkURL == expected { self?.setArtwork(image) }
            }
        }.resume()
    }

    /// Keeps the previous glow while the next cover loads, so the colour does not flash.
    private func setArtwork(_ image: NSImage?) {
        artwork = image
        if let image { glow = image.glowColors() ?? [] } else if source == nil { glow = [] }
    }

    // MARK: Controls

    func playPause() {
        if !command("toggle") { script("playpause") }
        position = livePosition(at: Date())
        positionDate = Date()
        isPlaying.toggle()
    }

    func next() {
        if !command("next") { script("next track"); after { self.refresh() } }
    }

    func previous() {
        if !command("previous") { script("previous track"); after { self.refresh() } }
    }

    func seek(to seconds: Double) {
        if !command("seek \(seconds)") { script("set player position to \(Int(seconds))") }
        position = seconds
        positionDate = Date()
    }

    func openPlayer() {
        guard let source else { return }
        if let app = NSRunningApplication(processIdentifier: source.pid) {
            app.activate()
        } else if let id = source.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    /// Starts a player on request; reading Now Playing never launches one.
    func launch(_ p: Player) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: p.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func script(_ command: String) {
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
