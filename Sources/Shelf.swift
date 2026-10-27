import AppKit
import QuickLookThumbnailing

struct ShelfItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var added = Date()
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
}

/// Files kept at hand. The shelf stores references only; files stay where they are.
final class Shelf: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]

    private let fileURL = supportDir.appendingPathComponent("shelf.json")
    private var timer: Timer?
    private var seenScreenshots = Set<String>()
    private var onScreenshot: ((URL) -> Void)?
    private let queue = DispatchQueue(label: "nook.shelf")

    private static let screenshotPrefixes = [
        "Снимок экрана", "Запись экрана", "Screenshot", "Screen Recording", "Bildschirmfoto", "Bildschirmaufnahme",
    ]

    func start(onScreenshot: @escaping (URL) -> Void) {
        self.onScreenshot = onScreenshot
        load()
        // Folder reads run off the main thread: the first one may wait on a macOS access prompt.
        queue.async { [weak self] in
            guard let self else { return }
            let initial = Set(self.currentScreenshots().map(\.path))
            DispatchQueue.main.async {
                self.seenScreenshots = initial
                self.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.scanScreenshots() }
            }
        }
    }

    /// Newest first; beyond 200 the oldest leave (and their thumbnails with them).
    func add(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.path == url.path }) {
            items.insert(ShelfItem(path: url.path), at: 0)
            makeThumbnail(for: url.path)
        }
        if items.count > 200 {
            items.suffix(from: 200).forEach { thumbnails[$0.path] = nil }
            items.removeLast(items.count - 200)
        }
        save()
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbnails[item.path] = nil
        save()
    }

    func clear() {
        items.removeAll()
        thumbnails.removeAll()
        save()
    }

    func airDrop(_ urls: [URL]) {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    func reveal(_ item: ShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func open(_ item: ShelfItem) {
        NSWorkspace.shared.open(item.url)
    }

    /// Puts the file itself on the clipboard, ready to paste in Finder, Mail or a chat.
    func copy(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item.url as NSURL])
    }

    // MARK: Screenshots

    private var screenshotFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent("Desktop")
    }

    private func currentScreenshots() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: screenshotFolder.path)) ?? []
        return names
            .filter { name in !name.hasPrefix(".") && Self.screenshotPrefixes.contains { name.hasPrefix($0) } }
            .map { screenshotFolder.appendingPathComponent($0) }
    }

    private func scanScreenshots() {
        queue.async { [weak self] in
            guard let self else { return }
            let found = self.currentScreenshots()
            DispatchQueue.main.async { self.addScreenshots(found) }
        }
    }

    private func addScreenshots(_ found: [URL]) {
        let fresh = found.filter { !seenScreenshots.contains($0.path) }
        guard !fresh.isEmpty else { return }
        fresh.forEach { seenScreenshots.insert($0.path) }
        add(fresh)
        if let last = fresh.last { onScreenshot?(last) }
    }

    // MARK: Thumbnails and storage

    private func makeThumbnail(for path: String) {
        let url = URL(fileURLWithPath: path)
        thumbnails[path] = NSWorkspace.shared.icon(forFile: path)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 120),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnails[path] = image }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = decoded
        items.forEach { makeThumbnail(for: $0.path) }
        queue.async { [weak self] in
            let missing = Set(decoded.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
            guard !missing.isEmpty else { return }
            DispatchQueue.main.async { self?.items.removeAll { missing.contains($0.id) } }
        }
    }

    /// Writes on the shelf queue; entries whose files were moved or deleted meanwhile are dropped.
    private func save() {
        let snapshot = items
        let url = fileURL
        queue.async { [weak self] in
            let existing = snapshot.filter { FileManager.default.fileExists(atPath: $0.path) }
            if let data = try? JSONEncoder().encode(existing) { try? data.write(to: url, options: [.atomic]) }
            let missing = Set(snapshot.map(\.id)).subtracting(existing.map(\.id))
            guard !missing.isEmpty else { return }
            DispatchQueue.main.async { self?.items.removeAll { missing.contains($0.id) } }
        }
    }
}
