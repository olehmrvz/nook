import AppKit

/// Download progress from the progress objects browsers publish for files in ~/Downloads
/// (the same ones Finder uses for its progress bars), plus a scan for finished files.
final class Downloads: ObservableObject {
    struct Active: Equatable {
        var name: String
        var fraction: Double?
    }

    @Published private(set) var active: Active?

    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    private var subscriber: Any?
    private var tracked: [ObjectIdentifier: (Progress, NSKeyValueObservation)] = [:]
    private var known = Set<String>()
    private var timer: Timer?
    private var onIsland: ((Island) -> Void)?
    private var ready = false
    private let queue = DispatchQueue(label: "nook.downloads")

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "opdownload"]

    func start(onIsland: @escaping (Island) -> Void) {
        self.onIsland = onIsland
        // Folder reads run off the main thread: the first one may wait on a macOS access prompt.
        queue.async { [weak self] in
            guard let self else { return }
            let names = Set(self.listing())
            DispatchQueue.main.async { self.known = names; self.ready = true }
        }
        subscriber = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
            DispatchQueue.main.async { self?.track(progress) }
            return { [weak self] in
                DispatchQueue.main.async { self?.untrack(progress) }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.scan() }
    }

    private func track(_ progress: Progress) {
        let observation = progress.observe(\.fractionCompleted, options: [.initial]) { [weak self] p, _ in
            DispatchQueue.main.async { self?.refresh() }
            _ = p
        }
        tracked[ObjectIdentifier(progress)] = (progress, observation)
        refresh()
    }

    private func untrack(_ progress: Progress) {
        tracked.removeValue(forKey: ObjectIdentifier(progress))
        refresh()
        scan()
    }

    private func refresh() {
        guard let (progress, _) = tracked.values.first(where: { !$0.0.isFinished && !$0.0.isCancelled }) else {
            if active != nil { scan() }
            return
        }
        let url = progress.fileURL ?? (progress.userInfo[.fileURLKey] as? URL)
        let name = Self.cleanName(url?.lastPathComponent ?? "Загрузка")
        let fraction = progress.totalUnitCount > 0 ? progress.fractionCompleted : nil
        active = Active(name: name, fraction: fraction)
    }

    private func listing() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") } ?? []
    }

    /// Finished files appear under their final name; partial ones keep a browser-specific extension.
    private func scan() {
        guard ready else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let names = self.listing()
            DispatchQueue.main.async { self.apply(names) }
        }
    }

    private func apply(_ names: [String]) {
        let partial = names.first { Self.partialExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        if tracked.isEmpty {
            let next = partial.map { Active(name: Self.cleanName($0), fraction: nil) }
            if next != active { active = next }
        }
        let fresh = names.filter { !known.contains($0) && !Self.partialExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        known = Set(names)
        for name in fresh {
            let path = folder.appendingPathComponent(name).path
            // Skip files that are still being written.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 120 else { continue }
            onIsland?(Island(kind: .download(name: name, path: path), seconds: 7))
        }
    }

    private static func cleanName(_ name: String) -> String {
        var n = name
        for ext in partialExtensions where (n as NSString).pathExtension.lowercased() == ext {
            n = (n as NSString).deletingPathExtension
        }
        return n
    }
}
