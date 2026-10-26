import AppKit

/// Countdown timer with an optional Pomodoro cycle (25 focus / 5 break, a long 15 break after four).
final class FocusTimer: ObservableObject {
    enum Phase: Equatable { case plain, focus, shortBreak, longBreak
        var title: String {
            switch self {
            case .plain: return "Таймер"
            case .focus: return "Фокус"
            case .shortBreak: return "Перерыв"
            case .longBreak: return "Длинный перерыв"
            }
        }
    }

    @Published private(set) var phase: Phase = .plain
    @Published private(set) var total: TimeInterval = 25 * 60
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var completedFocus = 0
    @Published var pomodoro = false

    var onFinish: ((String, String) -> Void)?
    private var ticker: Timer?

    var isRunning: Bool { endDate != nil }
    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at date: Date = Date()) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(date)) }
        return pausedRemaining ?? total
    }

    var progress: Double { total > 0 ? 1 - remaining() / total : 0 }

    func start(minutes: Double) {
        phase = pomodoro ? .focus : .plain
        run(seconds: minutes * 60)
    }

    func startPomodoro() {
        pomodoro = true
        completedFocus = 0
        phase = .focus
        run(seconds: 25 * 60)
    }

    private func run(seconds: TimeInterval) {
        total = seconds
        pausedRemaining = nil
        endDate = Date().addingTimeInterval(seconds)
        startTicker()
    }

    func pauseResume() {
        if let endDate {
            pausedRemaining = max(0, endDate.timeIntervalSinceNow)
            self.endDate = nil
            ticker?.invalidate()
        } else if let pausedRemaining {
            endDate = Date().addingTimeInterval(pausedRemaining)
            self.pausedRemaining = nil
            startTicker()
        }
    }

    func add(minutes: Double) {
        if let endDate {
            self.endDate = endDate.addingTimeInterval(minutes * 60)
            total += minutes * 60
        } else if let pausedRemaining {
            self.pausedRemaining = pausedRemaining + minutes * 60
            total += minutes * 60
        }
    }

    func reset() {
        ticker?.invalidate()
        endDate = nil
        pausedRemaining = nil
        phase = .plain
        pomodoro = false
        completedFocus = 0
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
    }

    private func tick() {
        objectWillChange.send()
        guard let endDate, endDate <= Date() else { return }
        ticker?.invalidate()
        self.endDate = nil
        NSSound(named: "Glass")?.play()
        switch phase {
        case .plain:
            onFinish?("Время вышло", "Таймер на \(Self.format(total)) закончился")
            phase = .plain
        case .focus:
            completedFocus += 1
            let long = completedFocus % 4 == 0
            onFinish?("Фокус завершён · \(completedFocus)", long ? "Длинный перерыв 15 мин" : "Перерыв 5 мин")
            phase = long ? .longBreak : .shortBreak
            run(seconds: (long ? 15 : 5) * 60)
        case .shortBreak, .longBreak:
            onFinish?("Перерыв окончен", "Следующий фокус 25 мин")
            phase = .focus
            run(seconds: 25 * 60)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
