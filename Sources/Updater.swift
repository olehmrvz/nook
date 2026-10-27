import AppKit
import Security

/// Updates from the GitHub releases of the Nook repository (published by `release.sh`).
/// Checks a minute after launch and every 6 hours, downloads a newer build, checks that it carries the same
/// signature as the running Nook, and installs it when the notch is idle; then Nook restarts itself.
final class Updater {
    static let repo = "olehmrvz/nook"

    /// Short text for the menu: what the updater last did.
    private(set) var status = ""
    /// Called on the main thread: true when nothing is open or waiting for an answer.
    var isIdle: () -> Bool = { true }

    private let queue = DispatchQueue(label: "nook.updates")
    private var timer: Timer?
    private var installTimer: Timer?
    private var busy = false
    /// A downloaded and verified Nook.app waiting for an idle moment.
    private var staged: (app: URL, version: Int)?

    /// Nook.zip is about 1–2 MB; anything far larger is not a real build.
    static let maxDownload = 50_000_000

    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
        timer?.tolerance = 600
    }

    /// `manual`: from the menu; runs even with automatic updates off, and reports "up to date".
    func check(manual: Bool = false, done: ((String) -> Void)? = nil) {
        guard manual || Settings.autoUpdate else { return }
        guard !busy, staged == nil else { done?(staged != nil ? "Обновление скачано и установится, когда Nook закрыт." : "Проверка уже идёт."); return }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            finish("Перенесите Nook в папку «Программы», тогда он сможет обновляться.", done)
            return
        }
        busy = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nook/\(Self.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, let version = Int(tag.drop { !$0.isNumber }),
                  let asset = (json["assets"] as? [[String: Any]])?.first(where: { ($0["name"] as? String) == "Nook.zip" }),
                  let link = asset["browser_download_url"] as? String, let url = URL(string: link),
                  (asset["size"] as? Int ?? 0) < Self.maxDownload
            else {
                self.finish("Не удалось проверить обновления. Попробую позже.", done)
                return
            }
            guard version > Self.build else {
                self.finish("Установлена последняя версия.", done)
                return
            }
            self.download(url, version: version, done: done)
        }.resume()
    }

    private func download(_ url: URL, version: Int, done: ((String) -> Void)?) {
        URLSession.shared.downloadTask(with: url) { [weak self] file, response, _ in
            guard let self else { return }
            let size = (try? file?.resourceValues(forKeys: [.fileSizeKey]))??.fileSize ?? 0
            guard let file, (response as? HTTPURLResponse)?.statusCode == 200, size < Self.maxDownload else {
                self.finish("Не удалось скачать обновление. Попробую позже.", done)
                return
            }
            // The downloaded file is deleted when this handler returns: unpack it right here.
            self.queue.sync {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NookUpdate-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let app = dir.appendingPathComponent("Nook.app")
                guard Self.run("/usr/bin/ditto", ["-x", "-k", file.path, dir.path]),
                      Self.sameSigner(app),
                      let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                      plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                      Int(plist["CFBundleVersion"] as? String ?? "") == version
                else {
                    try? FileManager.default.removeItem(at: dir)
                    self.finish("Обновление не прошло проверку подписи и не установлено.", done)
                    return
                }
                DispatchQueue.main.async {
                    self.busy = false
                    self.staged = (app, version)
                    self.status = "Скачана версия 1.\(version), установится, когда Nook закрыт."
                    done?(self.status)
                    self.installWhenIdle()
                }
            }
        }.resume()
    }

    private func finish(_ text: String, _ done: ((String) -> Void)?) {
        DispatchQueue.main.async {
            self.busy = false
            self.status = text
            done?(text)
        }
    }

    /// Waits for a moment when the panel is closed and no agent waits for an answer.
    private func installWhenIdle() {
        installTimer?.invalidate()
        installTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self, self.isIdle() else { return }
            self.installTimer?.invalidate()
            self.install()
        }
        installTimer?.tolerance = 5
    }

    private func install() {
        guard let staged else { return }
        let target = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        queue.async {
            // Checked again right before it replaces Nook: the copy waited in a temporary folder.
            guard Self.sameSigner(staged.app) else {
                DispatchQueue.main.async {
                    self.staged = nil
                    self.status = "Обновление изменилось после скачивания и не установлено."
                }
                return
            }
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged.app)
            } catch {
                DispatchQueue.main.async {
                    self.staged = nil
                    self.status = "Не удалось установить обновление: \(error.localizedDescription)"
                }
                return
            }
            _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path])
            // A helper starts the new copy once this one has exited (only one Nook may run at a time).
            let restart = Process()
            restart.executableURL = URL(fileURLWithPath: "/bin/sh")
            restart.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", target.path]
            try? restart.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// The new build must satisfy the running Nook's designated requirement: same bundle id and the
    /// same signing certificate. A tampered or foreign download fails here.
    static func sameSigner(_ app: URL) -> Bool {
        var me: SecCode?
        var mine: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
