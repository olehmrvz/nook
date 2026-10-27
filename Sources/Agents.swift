import AppKit

/// Claude Code and Codex sessions, fed by command hooks through a local unix socket.
/// Permission requests can be answered from the notch; unanswered ones fall back to the terminal.
final class AgentHub: ObservableObject {
    enum Provider: String, Codable { case claude, codex
        var title: String { self == .claude ? "Claude" : "Codex" }
    }
    enum Status: String, Codable { case idle, working, waiting, attention, done }
    enum Indicator { case working, waiting }

    struct Session: Identifiable, Codable {
        let id: String
        let provider: Provider
        var cwd: String
        var status: Status
        var tool: String?
        var updated: Date
        var pid: Int32
        var turnStarted: Date?
        /// What you asked for in this turn (first line of the prompt).
        var prompt: String?
        /// What the agent does right now, e.g. "Edit · Views.swift" or "Bash · npm test".
        var action: String?
        /// Its last answer, kept after the turn ends.
        var lastMessage: String?
        /// Text of the last Notification hook ("Claude is waiting for your input").
        var note: String?
        var toolCount = 0
        /// File names edited in this turn, in order.
        var edited: [String] = []
        var branch: String?
        /// Where the agent runs: terminal app, herdr workspace / tab, tmux pane (from its environment).
        var terminal: [String: String]?
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
        /// The tool's input as Claude sent it; questions and plans are rendered from it.
        let input: [String: Any]
        let fd: Int32
        let created = Date()
    }

    @Published private(set) var sessions: [Session] = [] { didSet { scheduleSave() } }
    @Published private(set) var permissions: [Permission] = []
    /// False when neither Claude Code nor Codex calls Nook's hook yet.
    @Published private(set) var hooksInstalled = true

    static let socketPath = supportDir.appendingPathComponent("agent.sock").path
    static let tokenURL = supportDir.appendingPathComponent("agent.token")
    static let hookURL = supportDir.appendingPathComponent("agent-hook.sh")
    static let sessionsURL = supportDir.appendingPathComponent("sessions.json")
    static let permissionTimeout: TimeInterval = 110

    private var token = ""
    /// Commands from the `Nook` command line (tabs, timer, prompter), set by the app delegate.
    var onShow: ((String) -> Void)?
    private var onPermission: (() -> Void)?
    private var onDone: ((Island) -> Void)?
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?
    private let io = DispatchQueue(label: "nook.agents")
    private var branchChecked = Set<String>()

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
        Self.writeShellScript()
        listen()
        restore()
        autoConnect()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.prune() }
    }

    // MARK: Persistence

    /// Sessions survive a restart of Nook: agents keep running, and their next hook may come much later.
    private func restore() {
        io.async { [weak self] in
            guard let data = try? Data(contentsOf: Self.sessionsURL),
                  let saved = try? JSONDecoder().decode([Session].self, from: data) else { return }
            let now = Date()
            let alive = saved.compactMap { session -> Session? in
                guard now.timeIntervalSince(session.updated) < 6 * 3600 else { return nil }
                if session.pid > 1 && !Self.isAgent(session.pid) { return nil }
                var session = session
                // The pending request died with the old process; the terminal asks instead.
                if session.status == .waiting { session.status = .attention }
                if session.status == .attention, Self.isIdleNote(session.note ?? "") { session.status = .done; session.note = nil }
                return session
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for session in alive where !self.sessions.contains(where: { $0.id == session.id }) {
                    self.sessions.append(session)
                    if session.pid > 1 { self.lookUpTerminal(for: session.id, pid: session.pid) }
                }
            }
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = sessions
        let work = DispatchWorkItem { [weak self] in
            self?.io.async {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? data.write(to: Self.sessionsURL, options: [.atomic])
                // Prompts and replies are private: owner-only, like clipboard.json.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.sessionsURL.path)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Agents Nook can connect: the folder that shows the agent is installed, and its hooks file.
    private static let agentConfigs = [(dir: ".claude", file: ".claude/settings.json", provider: "claude"),
                                       (dir: ".codex", file: ".codex/hooks.json", provider: "codex")]

    /// On a new Mac (or when an agent is installed later) Nook connects Claude Code and Codex by itself,
    /// once per agent: no trip to the menu, and hooks the person removed on purpose stay removed.
    private func autoConnect() {
        io.async { [weak self] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            var done = Settings.hooksAutoConnected
            for agent in Self.agentConfigs where !done.contains(agent.provider) {
                guard FileManager.default.fileExists(atPath: home.appendingPathComponent(agent.dir).path) else { continue }
                let url = home.appendingPathComponent(agent.file)
                do {
                    if (try? String(contentsOf: url, encoding: .utf8))?.contains(Self.hookURL.path) != true {
                        try Self.patch(url, provider: agent.provider)
                    }
                    if agent.provider == "codex" { try Self.enableCodexHooks() }
                    done.insert(agent.provider)
                } catch {
                    NSLog("Nook: could not connect \(agent.provider): \(error.localizedDescription)")
                }
            }
            Settings.hooksAutoConnected = done
            self?.checkHooks()
        }
    }

    func checkHooks() {
        io.async { [weak self] in
            let home = FileManager.default.homeDirectoryForCurrentUser
            let installed = Self.agentConfigs.map(\.file).contains { file in
                (try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8))?.contains(Self.hookURL.path) == true
            }
            DispatchQueue.main.async { self?.hooksInstalled = installed }
        }
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
        // At most 32 readers at once; a flood of idle connections is dropped instead of exhausting threads.
        let slots = DispatchSemaphore(value: 32)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(server, nil, nil)
                guard client >= 0 else { usleep(100_000); continue }
                guard slots.wait(timeout: .now()) == .success else { close(client); continue }
                Thread.detachNewThread { self?.read(client); slots.signal() }
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
        let started = Date()
        while data.count < 8_000_000 && Date().timeIntervalSince(started) < 10 {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if buffer[n - 1] == UInt8(ascii: "\n") { break }
        }
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["token"] as? String == token,
              let event = message["event"] as? String else { close(fd); return }
        if event == "Show" {
            // `Nook --show …`, `--timer …`, `--prompt`: authenticated, unlike a broadcast notification.
            close(fd)
            let name = message["name"] as? String ?? "home"
            DispatchQueue.main.async { self.onShow?(name) }
            return
        }
        if event == "Answer" {
            // `Nook --answer allow|always|deny|terminal`, authenticated like the hooks. Never from a process an
            // agent started: an agent could otherwise approve its own request with `Nook --answer always`.
            var peer: pid_t = 0
            var length = socklen_t(MemoryLayout<pid_t>.size)
            let known = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0
            close(fd)
            guard known, !Self.runsUnderAgent(peer) else { return }
            let decision: Decision? = switch message["decision"] as? String {
            case "allow": .allow
            case "always": .always
            case "deny": .deny
            default: nil
            }
            DispatchQueue.main.async { if let oldest = self.permissions.first { self.answer(oldest.id, with: decision) } }
            return
        }
        if message["provider"] as? String == "shell" {
            close(fd)
            if event == "CommandDone", let raw = message["raw"] as? [String: Any] {
                DispatchQueue.main.async { self.commandDone(raw) }
            }
            return
        }
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
            if !cwd.isEmpty && (sessions[i].cwd != cwd || !branchChecked.contains(cwd)) {
                sessions[i].cwd = cwd
                lookUpBranch(for: key, cwd: cwd)
            }
            if pid > 1 && (sessions[i].pid != pid || sessions[i].terminal == nil) {
                sessions[i].pid = pid
                lookUpTerminal(for: key, pid: pid)
            }
        }

        switch event {
        case "SessionStart":
            index.map { sessions[$0].status = .idle }
        case "UserPromptSubmit":
            resolve(sessionKey: key)
            if let i = index {
                sessions[i].status = .working
                sessions[i].tool = nil
                sessions[i].turnStarted = Date()
                sessions[i].prompt = Self.firstLine(raw["prompt"] as? String, limit: 160)
                sessions[i].action = nil
                sessions[i].lastMessage = nil
                sessions[i].note = nil
                sessions[i].toolCount = 0
                sessions[i].edited = []
                lookUpBranch(for: key, cwd: sessions[i].cwd)
            }
        case "PreToolUse":
            if let i = index {
                let tool = raw["tool_name"] as? String ?? ""
                let input = raw["tool_input"] as? [String: Any] ?? [:]
                sessions[i].status = .working
                sessions[i].tool = tool
                sessions[i].action = Self.describe(tool: tool, input: input)
                sessions[i].toolCount += 1
                if ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"].contains(tool),
                   let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
                    let name = (path as NSString).lastPathComponent
                    if !sessions[i].edited.contains(name) { sessions[i].edited.append(name) }
                }
            }
        case "PostToolUse":
            resolve(sessionKey: key)
            index.map { sessions[$0].status = .working }
        case "PermissionRequest":
            let tool = raw["tool_name"] as? String ?? "Инструмент"
            let request = Permission(sessionKey: key, provider: provider, tool: tool,
                                     summary: Self.summary(tool: tool, input: raw["tool_input"]),
                                     project: index.map { sessions[$0].project } ?? provider.title,
                                     suggestions: raw["permission_suggestions"],
                                     input: raw["tool_input"] as? [String: Any] ?? [:], fd: fd)
            permissions.append(request)
            index.map { sessions[$0].status = .waiting }
            onPermission?()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.permissionTimeout) { [weak self] in
                self?.answer(request.id, with: nil)
            }
        case "Notification":
            // "idle_prompt" ("Claude is waiting for your input") means the turn is over, not that it needs you.
            let text = raw["message"] as? String ?? ""
            let idle = raw["notification_type"] as? String == "idle_prompt" || Self.isIdleNote(text)
            if let i = index, sessions[i].status != .working, permissions.allSatisfy({ $0.sessionKey != key }) {
                if idle {
                    if sessions[i].status != .done { sessions[i].status = .done }
                    sessions[i].note = nil
                } else {
                    sessions[i].status = .attention
                    sessions[i].note = Self.firstLine(text, limit: 120)
                }
            }
        case "Stop":
            resolve(sessionKey: key)
            if let i = index {
                sessions[i].status = .done
                sessions[i].tool = nil
                let message = Self.plain(raw["last_assistant_message"] as? String ?? "")
                let duration = sessions[i].turnStarted.map { Date().timeIntervalSince($0) }
                sessions[i].turnStarted = nil
                sessions[i].action = nil
                sessions[i].lastMessage = message.isEmpty ? nil : String(message.prefix(220))
                // Short turns (a quick answer you are watching anyway) do not need an island.
                if (duration ?? 60) >= Settings.agentDoneMinSeconds {
                    onDone?(Island(kind: .agentDone(provider: provider.rawValue, project: sessions[i].project,
                                                    message: String(message.prefix(220)), duration: duration,
                                                    pid: sessions[i].pid, terminal: sessions[i].terminal ?? [:]),
                                   seconds: 8))
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
    /// `updatedInput` carries answers to AskUserQuestion; `mode` switches the permission mode on approval
    /// (e.g. "acceptEdits" after a plan); `message` explains a denial to the agent.
    func answer(_ id: UUID, with decision: Decision?, updatedInput: [String: Any]? = nil,
                mode: String? = nil, message: String? = nil) {
        guard let index = permissions.firstIndex(where: { $0.id == id }) else { return }
        let request = permissions.remove(at: index)
        if let decision {
            var body: [String: Any] = ["behavior": decision == .deny ? "deny" : "allow"]
            if decision == .deny { body["message"] = message ?? "Отклонено в Nook" }
            if decision == .always, let suggestions = request.suggestions { body["updatedPermissions"] = suggestions }
            if decision != .deny, let mode { body["updatedPermissions"] = [["type": "setMode", "mode": mode, "destination": "session"]] }
            if decision != .deny, let updatedInput { body["updatedInput"] = updatedInput }
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

    /// Drops sessions whose agent exited, finished ones after a while (the next prompt brings them back),
    /// and anything silent for six hours. Assigns only on a real change: no redraw or disk write every 5 s.
    private func prune() {
        let now = Date()
        let kept = sessions.filter { session in
            if session.pid > 1, kill(session.pid, 0) != 0, errno == ESRCH { return false }
            let quiet = now.timeIntervalSince(session.updated)
            if session.status == .done || session.status == .idle { return quiet <= Settings.finishedSessionTTL }
            return quiet <= 6 * 3600
        }
        if kept.count != sessions.count { sessions = kept }
    }

    private static func processName(_ pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }.lowercased()
    }

    /// The PID still belongs to an agent (and was not reused by another program).
    private static func isAgent(_ pid: Int32) -> Bool {
        guard let name = processName(pid) else { return false }
        return name.contains("claude") || name.contains("codex") || name == "node"
    }

    /// The process or one of its ancestors is an agent (claude, codex, node).
    private static func runsUnderAgent(_ start: pid_t) -> Bool {
        var pid = start
        for _ in 0..<64 where pid > 1 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return true }
            let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                .lowercased()
            if name.contains("claude") || name.contains("codex") || name == "node" { return true }
            pid = info.kp_eproc.e_ppid
        }
        return false
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

    // MARK: Session details

    /// One readable line from a markdown reply: no **, `, # or list dashes, single spaces.
    static func plain(_ markdown: String) -> String {
        var text = markdown
        for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
        let lines = text.split(whereSeparator: \.isNewline).map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            while l.hasPrefix("#") { l.removeFirst() }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { l.removeFirst(2) }
            return l.trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func isIdleNote(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("waiting for your input")
    }

    private static func firstLine(_ text: String?, limit: Int) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    /// "Edit · Views.swift", "Bash · npm test", "grifs · search_sections".
    static func describe(tool: String, input: [String: Any]) -> String {
        var name = tool
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            name = parts.count >= 2 ? "\(parts[0].components(separatedBy: "_").last ?? parts[0]) · \(parts[1])" : tool
            return name
        }
        func file(_ key: String) -> String? { (input[key] as? String).map { ($0 as NSString).lastPathComponent } }
        let detail: String? = switch tool {
        case "Bash": (input["description"] as? String) ?? firstLine(input["command"] as? String, limit: 60)
        case "Read", "Edit", "Write", "MultiEdit": file("file_path")
        case "NotebookEdit": file("notebook_path")
        case "Grep", "Glob": (input["pattern"] as? String).map { "«\($0)»" }
        case "WebFetch": (input["url"] as? String).flatMap { URL(string: $0)?.host }
        case "WebSearch": input["query"] as? String
        case "Task", "Agent": input["description"] as? String
        default: nil
        }
        guard let detail, !detail.isEmpty else { return name }
        return "\(name) · \(detail.count > 70 ? String(detail.prefix(70)) + "…" : detail)"
    }

    // MARK: Long shell commands

    static let shellScriptURL = supportDir.appendingPathComponent("nook.zsh")

    /// The notch can be seen by others (screen sharing, people nearby): values after "=" or ":" of
    /// secret-looking names, Authorization headers and long token-like words are shown as •••.
    static func masked(_ command: String) -> String {
        var text = command
        let rules = [
            #"(?i)(authorization:\s*(?:bearer|basic|token)?\s*)("[^"]*"|'[^']*'|[^\s"']+)"#,
            #"(?i)(--?(?:password|passwd|pass|token|secret|api-?key|key|auth)\s+)("[^"]*"|'[^']*'|\S+)"#,
            #"(?i)((?:token|secret|password|passwd|pwd|api[_-]?key|key|bearer|credential)[A-Za-z0-9_-]*\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)"#,
            #"(?i)(://[^:/\s]+:)([^@\s]+)(?=@)"#,
        ]
        for rule in rules {
            text = text.replacingOccurrences(of: rule, with: "$1•••", options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"\b[A-Za-z0-9_\-+/]{32,}={0,2}"#, with: "•••", options: .regularExpression)
    }

    /// A finished long command from the zsh integration: island unless you are looking at that terminal.
    private func commandDone(_ raw: [String: Any]) {
        func decoded(_ key: String) -> String {
            (raw[key] as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let command = decoded("cmd64").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let seconds = (raw["seconds"] as? NSNumber)?.doubleValue ?? 0
        let exit = (raw["exit"] as? NSNumber)?.intValue ?? 0
        let shell = (raw["shell"] as? NSNumber)?.int32Value ?? 0
        io.async { [weak self] in
            let env = shell > 1 ? Self.environment(of: shell).filter { Self.terminalKeys.contains($0.key) && !$0.value.isEmpty } : [:]
            let paneFocused = Self.herdrPaneFocused(env)
            DispatchQueue.main.async {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                let terminalInFront = front != nil && front == env["__CFBundleIdentifier"]
                // In front and (no herdr, or its pane is the one on screen): you saw it finish.
                if terminalInFront && (paneFocused ?? true) { return }
                self?.onDone?(Island(kind: .command(text: String(Self.masked(command).prefix(160)), seconds: seconds, exit: exit,
                                                    pid: shell, terminal: env), seconds: 7))
                if Settings.agentDoneSound { NSSound(named: exit == 0 ? "Glass" : "Basso")?.play() }
            }
        }
    }

    /// nil when the command did not run inside herdr.
    private static func herdrPaneFocused(_ env: [String: String]) -> Bool? {
        guard let pane = env["HERDR_PANE_ID"], let bin = herdrBinary else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.environment = childEnvironment
        process.arguments = ["pane", "get", pane]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil, finish(process, within: 2) else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let paneInfo = (root?["result"] as? [String: Any])?["pane"] as? [String: Any]
        return paneInfo?["focused"] as? Bool
    }

    static func writeShellScript() {
        let script = #"""
        # Nook: an island in the notch when a long command finishes. Sourced from ~/.zshrc; safe to remove.
        [[ -o interactive ]] || return
        zmodload zsh/datetime 2>/dev/null || return
        typeset -g __nook_cmd __nook_start
        __nook_preexec() { __nook_cmd=$1; __nook_start=$EPOCHREALTIME }
        __nook_precmd() {
          local code=$?
          [[ -n $__nook_start ]] || return
          local secs=$(( EPOCHREALTIME - __nook_start )) cmd=$__nook_cmd
          __nook_start=
          (( secs >= ${NOOK_MIN_SECONDS:-20} )) || return
          # Interactive programs are not "waiting for a result".
          local first=${${(z)cmd}[1]:t}
          [[ " vim nvim vi nano emacs less more man top htop btop ssh mosh tmux herdr claude codex watch tail fzf lazygit tig " == *" $first "* ]] && return
          local hook="$HOME/Library/Application Support/Nook/agent-hook.sh"
          [[ -x $hook ]] || return
          local c64=$(print -rn -- "$cmd" | /usr/bin/base64 | tr -d '\n') d64=$(print -rn -- "$PWD" | /usr/bin/base64 | tr -d '\n')
          printf '{"cmd64":"%s","cwd64":"%s","seconds":%d,"exit":%d,"shell":%d}' "$c64" "$d64" "${secs%.*}" "$code" "$$" \
            | "$hook" CommandDone shell &!
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook preexec __nook_preexec
        add-zsh-hook precmd __nook_precmd

        """#
        try? script.write(to: shellScriptURL, atomically: true, encoding: .utf8)
    }

    /// Adds one `source` line to ~/.zshrc (after a backup). Runs only from the menu, on the user's click.
    static func installShellIntegration() -> (ok: Bool, message: String) {
        writeShellScript()
        let rc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        let existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
        if existing.contains(shellScriptURL.path) { return (true, "Уже подключено. Новые вкладки терминала сообщают о долгих командах.") }
        do {
            if !existing.isEmpty {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let copy = rc.appendingPathExtension("bak-nook-\(stamp)")
                try existing.write(to: copy, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
            let path = shellScriptURL.path
            let line = "\n# Nook: island when a long command finishes\n[ -f \"\(path)\" ] && source \"\(path)\"\n"
            let handle = try FileHandle(forWritingTo: rc)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            return (true, "Добавлено в ~/.zshrc (копия рядом). Откройте новую вкладку терминала. Порог: 20 с, меняется через NOOK_MIN_SECONDS.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: Terminal

    /// Only identifiers are taken from an agent's environment, never a program path to run.
    private static let terminalKeys: Set<String> = ["__CFBundleIdentifier", "TERM_PROGRAM",
                                                    "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_PANE_ID",
                                                    "TMUX", "TMUX_PANE"]

    /// herdr from its usual install locations only.
    static var herdrBinary: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// Children get a minimal environment, so variables like PERL5OPT or DYLD_* never reach them.
    static var childEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
         "LANG": "en_US.UTF-8"]
    }

    /// Reads, once, where the agent runs from its environment (own processes only; no prompt).
    private func lookUpTerminal(for key: String, pid: Int32) {
        io.async { [weak self] in
            let env = Self.environment(of: pid).filter { Self.terminalKeys.contains($0.key) && !$0.value.isEmpty }
            DispatchQueue.main.async {
                guard let self, let i = self.sessions.firstIndex(where: { $0.id == key }) else { return }
                if self.sessions[i].terminal != env { self.sessions[i].terminal = env }
            }
        }
    }

    /// Environment of a process via KERN_PROCARGS2: argc, executable path, arguments, then KEY=VALUE strings.
    static func environment(of pid: Int32) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        // strings[0] is the executable path, then argc arguments, then the environment.
        var env: [String: String] = [:]
        for entry in strings.dropFirst(1 + Int(argc)) {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }

    /// Brings back the exact place an agent runs: its herdr tab or tmux pane, then the terminal app.
    /// In the user's own tmux directory (after resolving "..") and owned by the user: a socket elsewhere could
    /// be a fake server.
    private static func ownTmuxSocket(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix("/private/tmp/tmux-\(getuid())/") else { return false }
        var info = stat()
        return lstat(resolved, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFSOCK
    }

    static func focus(pid: Int32, terminal: [String: String]?) {
        let t = terminal ?? [:]
        DispatchQueue.global(qos: .userInitiated).async {
            if let workspace = t["HERDR_WORKSPACE_ID"], let tab = t["HERDR_TAB_ID"], let bin = herdrBinary {
                run(bin, ["workspace", "focus", workspace])
                run(bin, ["tab", "focus", tab])
            } else if let pane = t["TMUX_PANE"], let socket = t["TMUX"]?.split(separator: ",").first.map(String.init),
                      // Only the user's own tmux server directory: a socket elsewhere could be a fake server.
                      Self.ownTmuxSocket(socket),
                      let bin = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                        .first(where: FileManager.default.isExecutableFile(atPath:)) {
                run(bin, ["-S", socket, "select-window", "-t", pane])
                run(bin, ["-S", socket, "select-pane", "-t", pane])
            }
            DispatchQueue.main.async {
                if let id = t["__CFBundleIdentifier"],
                   let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                    app.activate()
                } else {
                    NotchModel.activateApp(owning: pid)
                }
            }
        }
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = childEnvironment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        _ = finish(process, within: 3)
    }

    /// Waits for a child with a deadline; a hung herdr or tmux is stopped instead of blocking a queue forever.
    private static func finish(_ process: Process, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return false }
        return true
    }

    /// Branch of the repository the agent works in. Skips folders macOS guards with a permission prompt.
    private func lookUpBranch(for key: String, cwd: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let guarded = ["/Desktop", "/Documents", "/Downloads", "/Library/Mobile Documents"].map { home + $0 }
        branchChecked.insert(cwd)
        guard !cwd.isEmpty, !guarded.contains(where: { cwd.hasPrefix($0) }) else { return }
        io.async { [weak self] in
            let branch = Self.gitBranch(at: cwd)
            DispatchQueue.main.async {
                guard let self, let i = self.sessions.firstIndex(where: { $0.id == key }) else { return }
                if self.sessions[i].branch != branch { self.sessions[i].branch = branch }
            }
        }
    }

    private static func gitBranch(at path: String) -> String? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<12 {
            let git = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir) {
                var gitDir = git
                if !isDir.boolValue {
                    // A worktree: ".git" is a file pointing at the real git dir.
                    guard let text = smallFile(git),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let target = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: target, relativeTo: dir).standardizedFileURL
                }
                guard let head = smallFile(gitDir.appendingPathComponent("HEAD")) else { return nil }
                let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
                return ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst(16).prefix(100)) : String(ref.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// A project folder is untrusted: ".git" or "HEAD" could be a link to /dev/zero or a pipe that never ends.
    /// Reads only a regular file of at most 4 KB.
    private static func smallFile(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4096,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4096)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func summary(tool: String, input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        if tool == "AskUserQuestion", let first = (input["questions"] as? [[String: Any]])?.first?["question"] as? String {
            return first
        }
        if tool == "ExitPlanMode", let plan = input["plan"] as? String { return firstLine(plan, limit: 200) ?? "План" }
        // The main field first, then every other field in full: what you approve is exactly what you can read.
        // (A tool could put a harmless "description" first and the real action in another field.)
        var rest = input
        var head = ""
        for key in ["command", "file_path", "path", "url", "pattern", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { head = value; rest.removeValue(forKey: key); break }
        }
        guard !rest.isEmpty else { return head }
        let details = rest.keys.sorted().map { key -> String in
            let value = rest[key]!
            if let text = value as? String { return "\(key): \(text)" }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
               let text = String(data: data, encoding: .utf8) { return "\(key): \(text)" }
            return "\(key): \(value)"
        }.joined(separator: "\n")
        return head.isEmpty ? details : "\(head)\n\n\(details)"
    }

    /// Client side of the command line (`--answer`, `--show`, `--timer`, `--prompt`):
    /// one JSON line to the running app over the owner-only socket, with the token.
    static func sendCommand(_ fields: [String: String]) -> Bool {
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let data = try? JSONSerialization.data(withJSONObject: fields.merging(["token": token]) { $1 })
        else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            bytes.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count - 1))) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return false }
        var line = data
        line.append(UInt8(ascii: "\n"))
        return line.withUnsafeBytes { send(fd, $0.baseAddress, line.count, 0) } == line.count
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
        case "$2" in codex) p=codex ;; shell) p=shell ;; *) p=claude ;; esac
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
        for agent in agentConfigs {
            let url = home.appendingPathComponent(agent.file)
            guard FileManager.default.fileExists(atPath: home.appendingPathComponent(agent.dir).path) else { continue }
            do {
                try patch(url, provider: agent.provider)
                if agent.provider == "codex" { try enableCodexHooks() }
                notes.append("✓ ~/\(agent.file)")
            } catch {
                ok = false
                notes.append("✗ ~/\(agent.file): \(error.localizedDescription)")
            }
        }
        if notes.isEmpty { return (false, "Claude Code и Codex не найдены: нет папок ~/.claude и ~/.codex.") }
        if agentConfigs.contains(where: { $0.provider == "codex" && FileManager.default.fileExists(atPath: home.appendingPathComponent($0.dir).path) }) {
            notes.append("Codex может один раз спросить, доверять ли хукам Nook — разреши.")
        }
        notes.append("Уже запущенные агенты перезапусти, чтобы они подхватили хуки.")
        return (ok, notes.joined(separator: "\n"))
    }

    /// Codex runs hooks only with `[features] hooks = true` in ~/.codex/config.toml. Changes just that key
    /// (after a backup); a config that sets features in another form is left alone.
    /// One copy per file (`<name>.bak-nook`), owner-only: these configs can hold tokens.
    private static func backup(_ data: Data, of url: URL) throws {
        let copy = url.appendingPathExtension("bak-nook")
        try data.write(to: copy, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
    }

    static func enableCodexHooks() throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml").resolvingSymlinksInPath()
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = original.components(separatedBy: "\n")
        func trimmed(_ i: Int) -> String { lines[i].trimmingCharacters(in: .whitespaces) }
        func key(_ i: Int) -> String { trimmed(i).components(separatedBy: "=").first?.trimmingCharacters(in: .whitespaces) ?? "" }
        func header(_ i: Int) -> String? {
            let line = trimmed(i).components(separatedBy: "#").first!.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), line.hasSuffix("]"), !line.hasPrefix("[[") || line.hasSuffix("]]") else { return nil }
            return line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        }
        // Several [features] tables, or anything unusual: leave the file to the person.
        let featureTables = lines.indices.filter { header($0) == "features" }
        if featureTables.count > 1 { return }
        if let start = featureTables.first {
            var end = start + 1
            while end < lines.count, header(end) == nil { end += 1 }
            if let i = (start + 1 ..< end).first(where: { key($0) == "hooks" }) {
                if trimmed(i).replacingOccurrences(of: " ", with: "").hasPrefix("hooks=true") { return }
                lines[i] = "hooks = true"
            } else {
                lines.insert("hooks = true", at: start + 1)
            }
        } else if lines.indices.contains(where: { key($0).hasPrefix("features") }) {
            return
        } else {
            if let last = lines.last, last.isEmpty { lines.removeLast() }
            lines += ["", "[features]", "hooks = true", ""]
        }
        if !original.isEmpty { try backup(Data(original.utf8), of: url) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func patch(_ link: URL, provider: String) throws {
        // Dotfile managers keep settings as links: write the real file, not over the link.
        let url = link.resolvingSymlinksInPath()
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "Nook", code: 1, userInfo: [NSLocalizedDescriptionKey: "не JSON-объект"])
            }
            root = parsed
            try backup(data, of: url)
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

extension AgentHub.Session {
    /// Tolerant decoding: fields added later may be missing in an older sessions.json.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(AgentHub.Provider.self, forKey: .provider)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        status = try c.decodeIfPresent(AgentHub.Status.self, forKey: .status) ?? .idle
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        turnStarted = try c.decodeIfPresent(Date.self, forKey: .turnStarted)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        toolCount = try c.decodeIfPresent(Int.self, forKey: .toolCount) ?? 0
        edited = try c.decodeIfPresent([String].self, forKey: .edited) ?? []
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        terminal = try c.decodeIfPresent([String: String].self, forKey: .terminal)
    }
}
