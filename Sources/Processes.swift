import Darwin
import Foundation

/// Your own processes that load the Mac for a long time: a dev server or test runner an agent left behind,
/// a stuck build. Samples every 10 s with proc_pidinfo (no shell, no Activity Monitor); reports a process once
/// when it keeps ≥ 90 % CPU for 2 minutes or uses ≥ 4 GB of memory.
final class ProcessWatch {
    struct Hog: Equatable {
        let pid: pid_t
        let name: String
        /// Its command line, secrets masked, for "node … vite dev".
        let command: String
        let cpu: Int
        let memory: UInt64
        /// Start time: a PID can be reused, so "Завершить" checks it is still the same process.
        let started: UInt64
        /// The process and its parents, to find the agent that started it.
        let ancestors: [pid_t]
    }

    /// On the main thread.
    var onHog: ((Hog) -> Void)?
    /// Islands cannot show now (screen locked): keep watching, report later.
    var isQuiet: () -> Bool = { false }

    static let cpuLimit = 90.0
    static let cpuSeconds: TimeInterval = 120
    static let memoryLimit: UInt64 = 4 << 30

    private let queue = DispatchQueue(label: "nook.processes", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var last: [pid_t: (cpu: UInt64, at: UInt64)] = [:]
    private var busySince: [pid_t: Date] = [:]
    /// Reported processes: not again for an hour.
    private var reported: [pid_t: Date] = [:]

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    private func sample() {
        guard Settings.processWatch else { last = [:]; busySince = [:]; return }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return }
        let now = mach_absolute_time()
        let uid = getuid(), me = getpid()
        let ignored = Settings.ignoredProcesses
        let quiet = isQuiet()
        var seen = Set<pid_t>()
        for pid in pids.prefix(Int(filled)) where pid > 1 && pid != me {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
                  bsd.pbi_uid == uid else { continue }
            var task = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
            seen.insert(pid)
            let cpuTicks = task.pti_total_user + task.pti_total_system
            defer { last[pid] = (cpuTicks, now) }
            guard let previous = last[pid], now > previous.at, cpuTicks >= previous.cpu else { continue }
            // CPU time and wall time are both in Mach ticks here, so their ratio needs no conversion.
            let percent = Double(cpuTicks - previous.cpu) / Double(now - previous.at) * 100
            if percent >= Self.cpuLimit {
                if busySince[pid] == nil { busySince[pid] = Date() }
            } else {
                busySince[pid] = nil
            }
            let name = Self.name(of: bsd)
            if let when = reported[pid], Date().timeIntervalSince(when) < 3600 { continue }
            guard !quiet, !ignored.contains(name) else { continue }
            let busy = busySince[pid].map { Date().timeIntervalSince($0) >= Self.cpuSeconds } ?? false
            var memory: UInt64 = 0
            if task.pti_resident_size >= Self.memoryLimit / 2 {
                var usage = rusage_info_v4()
                let ok = withUnsafeMutablePointer(to: &usage) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
                }
                memory = ok == 0 ? usage.ri_phys_footprint : task.pti_resident_size
            }
            guard busy || memory >= Self.memoryLimit else { continue }
            reported[pid] = Date()
            let hog = Hog(pid: pid, name: name, command: Self.command(of: pid, fallback: name), cpu: Int(percent.rounded()),
                          memory: memory, started: bsd.pbi_start_tvsec, ancestors: Self.ancestors(of: pid))
            DispatchQueue.main.async { self.onHog?(hog) }
        }
        // Forget exited processes.
        last = last.filter { seen.contains($0.key) }
        busySince = busySince.filter { seen.contains($0.key) }
        reported = reported.filter { seen.contains($0.key) }
    }

    private static func name(of bsd: proc_bsdinfo) -> String {
        var info = bsd
        let long = withUnsafeBytes(of: &info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !long.isEmpty { return long }
        return withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// The command line (KERN_PROCARGS2: argc, executable path, then the arguments), with secrets masked.
    private static func command(of pid: pid_t, fallback: String) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return fallback }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return fallback }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        let strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        let arguments = strings.dropFirst().prefix(argc).enumerated()
            .map { $0.offset == 0 ? ($0.element as NSString).lastPathComponent : $0.element }
        guard !arguments.isEmpty else { return fallback }
        return String(AgentHub.masked(arguments.joined(separator: " ")).prefix(160))
    }

    private static func ancestors(of pid: pid_t) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        for _ in 0..<16 where current > 1 {
            chain.append(current)
            current = NotchModel.parentPID(of: current)
        }
        return chain
    }

    /// Ends the process if it is still the same one: SIGTERM, then SIGKILL after 3 s if it is still there.
    static func terminate(_ hog: Hog) {
        DispatchQueue.global(qos: .userInitiated).async {
            func same() -> Bool {
                var bsd = proc_bsdinfo()
                return proc_pidinfo(hog.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
                    && bsd.pbi_uid == getuid() && bsd.pbi_start_tvsec == hog.started
            }
            guard hog.pid > 1, hog.pid != getpid(), same() else { return }
            kill(hog.pid, SIGTERM)
            for _ in 0..<30 {
                usleep(100_000)
                if !same() { return }
            }
            if same() { kill(hog.pid, SIGKILL) }
        }
    }
}
