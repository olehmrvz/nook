import AppKit
import Contacts
import SQLite3

/// Shows new system notifications (messages, calls, any app) as islands.
/// Reads the Notification Center database read-only, which needs Full Disk Access.
final class NotificationWatcher: ObservableObject {
    @Published private(set) var hasAccess = false

    private var db: OpaquePointer?
    private var lastID: Int64 = -1
    private var timer: Timer?
    private var onIsland: ((Island) -> Void)?
    private let logURL = supportDir.appendingPathComponent("notifications-debug.log")
    private var logged = 0

    private static var databasePaths: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ["\(home)/Library/Group Containers/group.com.apple.usernoted/db2/db"]
        if let dir = Self.darwinUserDir() { paths.append("\(dir)/com.apple.notificationcenter/db2/db") }
        return paths
    }

    private static let callApps: Set<String> = [
        "com.apple.FaceTime", "com.apple.TelephonyUtilities", "com.apple.mobilephone", "com.apple.InCallService",
    ]

    func start(onIsland: @escaping (Island) -> Void) {
        self.onIsland = onIsland
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private func openDatabase() -> Bool {
        if db != nil { return true }
        for path in Self.databasePaths where FileManager.default.isReadableFile(atPath: path) {
            var handle: OpaquePointer?
            if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
                db = handle
                return true
            }
            sqlite3_close(handle)
        }
        return false
    }

    private func poll() {
        guard openDatabase() else {
            if hasAccess { hasAccess = false }
            return
        }
        if !hasAccess { hasAccess = true }
        if lastID < 0 {
            lastID = scalar("SELECT IFNULL(MAX(rec_id), 0) FROM record") ?? 0
            return
        }
        guard Settings.notificationIslands else { return }
        let sql = "SELECT r.rec_id, a.identifier, r.data FROM record r JOIN app a ON r.app_id = a.app_id WHERE r.rec_id > ? ORDER BY r.rec_id LIMIT 20"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_close(db)
            db = nil
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastID)
        while sqlite3_step(stmt) == SQLITE_ROW {
            lastID = sqlite3_column_int64(stmt, 0)
            let bundleID = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            guard let blob = sqlite3_column_blob(stmt, 2) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
            handle(bundleID: bundleID, data: data)
        }
    }

    private func handle(bundleID: String, data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            log("\(bundleID): undecodable record")
            return
        }
        let req = plist["req"] as? [String: Any] ?? [:]
        let title = (req["titl"] as? String) ?? ""
        let subtitle = (req["subt"] as? String) ?? ""
        let body = (req["body"] as? String) ?? ""
        log("\(bundleID): keys=\(plist.keys.sorted()) req=\(req.keys.sorted()) title=\(!title.isEmpty) body=\(!body.isEmpty)")

        let ownID = Bundle.main.bundleIdentifier ?? "dev.nook.app"
        guard bundleID != ownID, !Settings.mutedApps.contains(bundleID), !(title.isEmpty && body.isEmpty) else { return }
        let appName = Self.appName(for: bundleID)

        if Self.callApps.contains(bundleID) || bundleID.lowercased().contains("facetime") {
            onIsland?(Island(kind: .call(name: title.isEmpty ? body : title, bundleID: bundleID), seconds: 20))
            return
        }
        let heading = subtitle.isEmpty ? title : "\(title) · \(subtitle)"
        onIsland?(Island(kind: .notification(bundleID: bundleID, app: appName, title: heading, body: body), seconds: 6))
    }

    private func scalar(_ sql: String) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    /// Format check log: bundle ids and key names only, never message text.
    private func log(_ line: String) {
        guard logged < 40 else { return }
        logged += 1
        let entry = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    static func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    static func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    static func open(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// Caller photo from Contacts, matched by display name. Asks for Contacts access the first time.
    static func contactImage(named name: String, completion: @escaping (NSImage?) -> Void) {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { granted, _ in
            guard granted, !name.isEmpty else { return DispatchQueue.main.async { completion(nil) } }
            let keys = [CNContactThumbnailImageDataKey as CNKeyDescriptor, CNContactImageDataAvailableKey as CNKeyDescriptor]
            let contact = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys).first
            let image = contact?.thumbnailImageData.flatMap(NSImage.init(data:))
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func darwinUserDir() -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let length = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
        guard length > 0 else { return nil }
        let dir = String(cString: buffer)
        return dir.hasSuffix("/") ? String(dir.dropLast()) : dir
    }
}
