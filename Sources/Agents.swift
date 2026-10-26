import AppKit

/// Claude Code and Codex sessions, fed by command hooks through a local unix socket.
/// Permission requests can be answered from the notch; unanswered ones fall back to the terminal.
final class AgentHub: ObservableObject {
    enum Provider: String { case claude, codex
        var title: String { self == .claude ? "Claude" : "Codex" }
    }
    enum Status { case idle, working, waiting, attention, done }
    enum Indicator { case working, waiting }

    struct Session: Identifiable {
        let id: String
        let provider: Provider
        var cwd: String
        var status: Status
        var tool: String?
        var updated: Date
        var pid: Int32
        var turnStarted: Date?
        var project: String { cwd.isEmpty ? provider.title : (cwd as NSString).lastPathComponent }
    }

    struct Permission: Identifiable {
        let id = UUID()
        let sessionKey: String
        let provider: Provider
        let tool: String
        let summary: String
        let project: String
        let suggestions: Any?
        let fd: Int32
        let created = Date()
    }

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var permissions: [Permission] = []

    static let socketPath = supportDir.appendingPathComponent("agent.sock").path
    static let tokenURL = supportDir.appendingPathComponent("agent.token")
    static let hookURL = supportDir.appendingPathComponent("agent-hook.sh")
    static let permissionTimeout: TimeInterval = 110

    private var token = ""
    private var onPermission: (() -> Void)?
    private var onDone: ((Island) -> Void)?
    private var timer: Timer?

    var indicator: Indicator? {
        if !permissions.isEmpty { return .waiting }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        return nil
    }

    func start(onPermission: @escaping () -> Void, onDone: @escaping (Island) -> Void) {
        self.onPermission = onPermission
        self.onDone = onDone
        signal(SIGPIPE, SIG_IGN)
        token = Self.loadToken()
        Self.writeHookScript()
        listen()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.prune() }
    }

    // MARK: Socket server

    private func listen() {
        let path = Self.socketPath
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count - 1))) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(server); return }
        chmod(path, 0o600)
        Darwin.listen(server, 32)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(server, nil, nil)
                guard client >= 0 else { continue }
                Thread.detachNewThread { self?.read(client) }
            }
        }
    }

    private func read(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count < 8_000_000 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if buffer[n - 1] == UInt8(ascii: "\n") { break }
        }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["token"] as? String == token,
              let event = message["event"] as? String else { close(fd); return }
        let provider = Provider(rawValue: message["provider"] as? String ?? "") ?? .claude
        let pid = Self.agentProcess(from: (message["pid"] as? NSNumber)?.int32Value ?? 0)
        let raw = message["raw"] as? [String: Any] ?? [:]
        if event != "PermissionRequest" { close(fd) }
        DispatchQueue.main.async { self.receive(event: event, provider: provider, pid: pid, raw: raw, fd: fd) }
    }

    // MARK: Events

    private func receive(event: String, provider: Provider, pid: Int32, raw: [String: Any], fd: Int32) {
        let sid = raw["session_id"] as? String ?? "pid-\(pid)"
        let key = "\(provider.rawValue):\(sid)"
        let cwd = raw["cwd"] as? String ?? ""
        var index = sessions.firstIndex { $0.id == key }
        if index == nil && event != "SessionEnd" {
            sessions.insert(Session(id: key, provider: provider, cwd: cwd, status: .idle, tool: nil,
                                    updated: Date(), pid: pid, turnStarted: nil), at: 0)
            index = 0
        }
        if let i = index {
            sessions[i].updated = Date()
            if !cwd.isEmpty { sessions[i].cwd = cwd }
            if pid > 1 { sessions[i].pid = pid }
        }

        switch event {
        case "SessionStart":
            index.map { sessions[$0].status = .idle }
        case "UserPromptSubmit":
            resolve(sessionKey: key)
            index.map { sessions[$0].status = .working; sessions[$0].tool = nil; sessions[$0].turnStarted = Date() }
        case "PreToolUse":
            index.map { sessions[$0].status = .working; sessions[$0].tool = raw["tool_name"] as? String }
        case "PostToolUse":
            resolve(sessionKey: key)
            index.map { sessions[$0].status = .working }
        case "PermissionRequest":
            let tool = raw["tool_name"] as? String ?? "Инструмент"
            let request = Permission(sessionKey: key, provider: provider, tool: tool,
                                     summary: Self.summary(tool: tool, input: raw["tool_input"]),
                                     project: index.map { sessions[$0].project } ?? provider.title,
                                     suggestions: raw["permission_suggestions"], fd: fd)
            permissions.append(request)
            index.map { sessions[$0].status = .waiting }
            onPermission?()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.permissionTimeout) { [weak self] in
                self?.answer(request.id, with: nil)
            }
        case "Notification":
            if let i = index, sessions[i].status != .working, permissions.allSatisfy({ $0.sessionKey != key }) {
                sessions[i].status = .attention
            }
        case "Stop":
            resolve(sessionKey: key)
            if let i = index {
                sessions[i].status = .done
                sessions[i].tool = nil
                let message = (raw["last_assistant_message"] as? String ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                let duration = sessions[i].turnStarted.map { Date().timeIntervalSince($0) }
                sessions[i].turnStarted = nil
                // Short turns (a quick answer you are watching anyway) do not need an island.
                if (duration ?? 60) >= Settings.agentDoneMinSeconds {
                    onDone?(Island(kind: .agentDone(provider: provider.rawValue, project: sessions[i].project,
                                                    message: String(message.prefix(220)), duration: duration,
                                                    pid: sessions[i].pid), seconds: 8))
                    if Settings.agentDoneSound { NSSound(named: "Glass")?.play() }
                }
            }
        case "SessionEnd":
            resolve(sessionKey: key)
            sessions.removeAll { $0.id == key }
        default:
            break
        }
    }

    /// Answers a pending request. `nil` closes it without a decision, so the terminal asks as usual.
    func answer(_ id: UUID, with decision: Decision?) {
        guard let index = permissions.firstIndex(where: { $0.id == id }) else { return }
        let request = permissions.remove(at: index)
        if let decision {
            var body: [String: Any] = ["behavior": decision == .deny ? "deny" : "allow"]
            if decision == .deny { body["message"] = "Отклонено в Nook" }
            if decision == .always, let suggestions = request.suggestions { body["updatedPermissions"] = suggestions }
            let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]]
            if var data = try? JSONSerialization.data(withJSONObject: output) {
                data.append(UInt8(ascii: "\n"))
                _ = data.withUnsafeBytes { send(request.fd, $0.baseAddress, data.count, 0) }
            }
            if let i = sessions.firstIndex(where: { $0.id == request.sessionKey }) {
                sessions[i].status = decision == .deny ? .idle : .working
            }
        }
        close(request.fd)
    }

    enum Decision { case allow, always, deny }

    private func resolve(sessionKey: String) {
        permissions.filter { $0.sessionKey == sessionKey }.forEach { answer($0.id, with: nil) }
    }

    private func prune() {
        let now = Date()
        sessions.removeAll { session in
            if session.pid > 1, kill(session.pid, 0) != 0, errno == ESRCH { return true }
            return now.timeIntervalSince(session.updated) > 6 * 3600
        }
    }

    /// Walks up from the hook's parent to the claude / codex process, so liveness checks survive
    /// an intermediate shell. Returns 0 when no agent process is found (then only age prunes the session).
    private static func agentProcess(from start: Int32) -> Int32 {
        var pid = start
        for _ in 0..<6 where pid > 1 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
            let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                .lowercased()
            if name.contains("claude") || name.contains("codex") || name == "node" { return pid }
            pid = info.kp_eproc.e_ppid
        }
        return 0
    }

    private static func summary(tool: String, input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        for key in ["command", "file_path", "path", "url", "pattern", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        if let data = try? JSONSerialization.data(withJSONObject: input), let s = String(data: data, encoding: .utf8) {
            return String(s.prefix(300))
        }
        return ""
    }

    // MARK: Hook installation

    private static func loadToken() -> String {
        if let existing = try? String(contentsOf: tokenURL, encoding: .utf8), existing.count >= 32 {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
        chmod(tokenURL.path, 0o600)
        return token
    }

    static func writeHookScript() {
        let script = """
        #!/bin/sh
        # Nook agent hook: forwards Claude Code / Codex hook events to Nook over a local socket.
        e=$1
        case "$2" in codex) p=codex ;; *) p=claude ;; esac
        s="\(socketPath)"
        t=$(cat "\(tokenURL.path)" 2>/dev/null)
        d=$(cat)
        [ -S "$s" ] || exit 0
        [ -n "$d" ] || d='{}'
        m=$(printf '{"provider":"%s","event":"%s","pid":%s,"token":"%s","raw":%s}' "$p" "$e" "$PPID" "$t" "$d")
        if [ "$e" = "PermissionRequest" ]; then
          printf '%s\\n' "$m" | /usr/bin/nc -U -w 120 "$s" 2>/dev/null
        else
          printf '%s\\n' "$m" | /usr/bin/nc -U -w 1 "$s" >/dev/null 2>&1
        fi
        # Always succeed: Nook being closed must never show a hook error in the agent.
        exit 0

        """
        try? script.write(to: hookURL, atomically: true, encoding: .utf8)
        chmod(hookURL.path, 0o700)
    }

    static let hookEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                             "PermissionRequest", "Notification", "Stop"]

    /// Adds Nook hooks to Claude Code and Codex and removes Notchy's. Other hooks stay untouched.
    static func installHooks() -> (ok: Bool, message: String) {
        writeHookScript()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var notes: [String] = []
        var ok = true
        for (file, provider) in [(".claude/settings.json", "claude"), (".codex/hooks.json", "codex")] {
            let url = home.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { continue }
            do {
                try patch(url, provider: provider)
                notes.append("✓ ~/\(file)")
            } catch {
                ok = false
                notes.append("✗ ~/\(file): \(error.localizedDescription)")
            }
        }
        return (ok, notes.joined(separator: "\n"))
    }

    private static func patch(_ url: URL, provider: String) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Nook", code: 1, userInfo: [NSLocalizedDescriptionKey: "не JSON-объект"])
            }
            root = parsed
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try data.write(to: url.appendingPathExtension("bak-nook-\(stamp)"))
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let suffix = provider == "codex" ? " codex" : ""
        func isOurs(_ command: String) -> Bool {
            command.contains("/Notchy/agent-hook.sh") || command.contains("/Nook/agent-hook.sh")
        }
        for event in Set(hookEvents).union(hooks.keys) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = groups.compactMap { group in
                var group = group
                let inner = (group["hooks"] as? [[String: Any]] ?? []).filter { !isOurs($0["command"] as? String ?? "") }
                if inner.isEmpty { return nil }
                group["hooks"] = inner
                return group
            }
            if hookEvents.contains(event) {
                var hook: [String: Any] = ["type": "command", "command": "\"\(hookURL.path)\" \(event)\(suffix)"]
                if event == "PermissionRequest" { hook["timeout"] = 130 }
                groups.insert(["hooks": [hook]], at: 0)
            }
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        root["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: url, options: [.atomic])
    }
}
