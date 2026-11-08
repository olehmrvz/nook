import AppKit
import Security

/// Updates from the GitHub releases of the Nook repository (published by `release.sh`).
/// Checks a minute after launch and every 6 hours, downloads a newer build and checks that it is signed by Nook
/// (`signedByNook`). Then it offers it (a drop, Settings → Updates, the menu); it installs only when asked,
/// and Nook restarts itself.
final class Updater {
    static let repo = "olehmrvz/nook"

    /// Short text for the menu: what the updater last did.
    private(set) var status = ""
    /// Called on the main thread when a checked build is ready to install (again on every later check).
    var onReady: ((Int) -> Void)?
    /// The version waiting to be installed.
    var readyVersion: Int? { staged?.version }
    /// Called on the main thread when «Установить» did not work, with the reason: the drop that asked is gone.
    var onInstallFailed: ((String) -> Void)?

    private let queue = DispatchQueue(label: "nook.updates")
    private var timer: Timer?
    private var busy = false
    /// A downloaded and verified Nook.app waiting until the person clicks Install.
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
        guard !busy else { done?(L("Проверка уже идёт.")); return }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            finish(L("Перенесите Nook в папку «Программы», тогда он сможет обновляться."), done)
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
                self.finish(L("Не удалось проверить обновления. Попробую позже."), done)
                return
            }
            guard version > Self.build else {
                self.finish(L("Установлена последняя версия."), done)
                return
            }
            DispatchQueue.main.async {
                // Already downloaded and still the newest: offer it again instead of downloading it twice. A newer
                // release replaces the one that waited.
                if let staged = self.staged, staged.version >= version {
                    self.busy = false
                    if !manual { self.onReady?(staged.version) }
                    self.status = L("Версия 1.\(staged.version) скачана: нажмите «Установить».")
                    done?(self.status)
                    return
                }
                self.download(url, version: version, done: done)
            }
        }.resume()
    }

    private func download(_ url: URL, version: Int, done: ((String) -> Void)?) {
        URLSession.shared.downloadTask(with: url) { [weak self] file, response, _ in
            guard let self else { return }
            let size = (try? file?.resourceValues(forKeys: [.fileSizeKey]))??.fileSize ?? 0
            guard let file, (response as? HTTPURLResponse)?.statusCode == 200, size < Self.maxDownload else {
                self.finish(L("Не удалось скачать обновление. Попробую позже."), done)
                return
            }
            // The downloaded file is deleted when this handler returns: unpack it right here.
            self.queue.sync {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NookUpdate-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let app = dir.appendingPathComponent("Nook.app")
                guard Self.run("/usr/bin/ditto", ["-x", "-k", file.path, dir.path]),
                      Self.signedByNook(app),
                      let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                      plist["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                      Int(plist["CFBundleVersion"] as? String ?? "") == version
                else {
                    try? FileManager.default.removeItem(at: dir)
                    self.finish(L("Обновление не прошло проверку подписи и не установлено."), done)
                    return
                }
                DispatchQueue.main.async {
                    self.busy = false
                    if let old = self.staged { self.queue.async { try? FileManager.default.removeItem(at: old.app.deletingLastPathComponent()) } }
                    self.staged = (app, version)
                    self.status = L("Версия 1.\(version) скачана: нажмите «Установить».")
                    done?(self.status)
                    self.onReady?(version)
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

    /// Replaces this copy with the downloaded one and restarts (the drop's «Установить», Settings, the menu).
    func install() {
        guard let staged else { return }
        let target = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        queue.async {
            // Checked again right before it replaces Nook: the copy waited in a temporary folder.
            guard Self.signedByNook(staged.app) else {
                DispatchQueue.main.async {
                    self.staged = nil
                    self.status = L("Обновление изменилось после скачивания и не установлено.")
                    self.onInstallFailed?(self.status)
                }
                return
            }
            do {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: staged.app)
            } catch {
                DispatchQueue.main.async {
                    self.staged = nil
                    self.status = L("Не удалось установить обновление: \(error.localizedDescription)")
                    self.onInstallFailed?(self.status)
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

    /// Official releases (release.sh): Nook's Developer ID, team T2KMY2TV9W. It names the team, not one
    /// certificate, so a renewed certificate keeps updates working.
    static let releaseRequirement = "identifier \"dev.nook.app\" and anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        + " and certificate leaf[subject.OU] = T2KMY2TV9W"

    /// Official releases before Developer ID (v10 and earlier): "Nook Local Signing" of the Nook repository.
    static let legacyRequirement = "identifier \"dev.nook.app\""
        + " and certificate leaf = H\"76a699582536149bb53212178f4a1b2a2dc15cc1\""

    /// The new build must satisfy the running Nook's designated requirement (same bundle id and signing
    /// certificate). A copy signed like the old releases also takes official Developer ID releases, so it can
    /// move to them; a contributor's own build (ad-hoc, another certificate) does not. A tampered or foreign
    /// download fails here.
    static func signedByNook(_ app: URL) -> Bool {
        var me: SecCode?
        var mine: SecStaticCode?
        var own: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &own) == errSecSuccess, let own,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { return false }
        var accepted = [own]
        var legacy: SecRequirement?
        var release: SecRequirement?
        if SecRequirementCreateWithString(legacyRequirement as CFString, [], &legacy) == errSecSuccess, let legacy,
           SecCodeCheckValidity(me, [], legacy) == errSecSuccess,
           SecRequirementCreateWithString(releaseRequirement as CFString, [], &release) == errSecSuccess, let release {
            accepted.append(release)
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return accepted.contains { SecStaticCodeCheckValidity(candidate, flags, $0) == errSecSuccess }
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
