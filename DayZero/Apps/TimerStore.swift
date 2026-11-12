import Foundation
import Observation
import UserNotifications

/// Countdown and stopwatch that keep time across backgrounding and relaunches:
/// both are stored as dates, and the countdown's end is a local notification.
@Observable
final class TimerStore {
    static let shared = TimerStore()
    private let defaults = UserDefaults.standard
    static let notificationID = "countdown-done"

    // Countdown
    private(set) var countdownEnd: Date? { didSet { save() } }
    private(set) var pausedRemaining: TimeInterval? { didSet { save() } }
    var lastDuration: TimeInterval = 600 { didSet { save() } }

    // Stopwatch
    private(set) var stopwatchStart: Date? { didSet { save() } }
    private(set) var stopwatchAccumulated: TimeInterval = 0 { didSet { save() } }
    private(set) var laps: [TimeInterval] = [] { didSet { save() } }

    init() {
        countdownEnd = defaults.object(forKey: "timer.end") as? Date
        pausedRemaining = defaults.object(forKey: "timer.paused") as? TimeInterval
        lastDuration = defaults.object(forKey: "timer.last") as? TimeInterval ?? 600
        stopwatchStart = defaults.object(forKey: "sw.start") as? Date
        stopwatchAccumulated = defaults.double(forKey: "sw.acc")
        laps = defaults.array(forKey: "sw.laps") as? [TimeInterval] ?? []
        if let end = countdownEnd, end < .now { countdownEnd = nil }
    }

    private func save() {
        defaults.set(countdownEnd, forKey: "timer.end")
        defaults.set(pausedRemaining, forKey: "timer.paused")
        defaults.set(lastDuration, forKey: "timer.last")
        defaults.set(stopwatchStart, forKey: "sw.start")
        defaults.set(stopwatchAccumulated, forKey: "sw.acc")
        defaults.set(laps, forKey: "sw.laps")
    }

    // MARK: Countdown

    func countdownRemaining(at now: Date = .now) -> TimeInterval? {
        if let pausedRemaining { return pausedRemaining }
        guard let countdownEnd else { return nil }
        return max(0, countdownEnd.timeIntervalSince(now))
    }

    var countdownRunning: Bool { countdownEnd != nil && pausedRemaining == nil }
    var countdownActive: Bool { countdownEnd != nil || pausedRemaining != nil }

    func startCountdown(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        lastDuration = seconds
        pausedRemaining = nil
        countdownEnd = Date.now.addingTimeInterval(seconds)
        schedule(seconds)
    }

    func pauseCountdown() {
        guard let remaining = countdownRemaining() else { return }
        pausedRemaining = remaining
        countdownEnd = nil
        cancelNotification()
    }

    func resumeCountdown() {
        guard let remaining = pausedRemaining else { return }
        pausedRemaining = nil
        countdownEnd = Date.now.addingTimeInterval(remaining)
        schedule(remaining)
    }

    func cancelCountdown() {
        countdownEnd = nil
        pausedRemaining = nil
        cancelNotification()
    }

    /// Called by the view when the countdown reaches zero on screen.
    func countdownFinished() { countdownEnd = nil }

    private func schedule(_ seconds: TimeInterval) {
        cancelNotification()
        Task {
            await Reminders.notifyNow(id: Self.notificationID, title: "Timer done",
                                      body: "Your \(Self.format(lastDuration, tenths: false)) timer has finished.",
                                      after: seconds)
        }
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }

    // MARK: Stopwatch

    func stopwatchElapsed(at now: Date = .now) -> TimeInterval {
        stopwatchAccumulated + (stopwatchStart.map { now.timeIntervalSince($0) } ?? 0)
    }

    var stopwatchRunning: Bool { stopwatchStart != nil }

    func startStopwatch() { if stopwatchStart == nil { stopwatchStart = .now } }

    func stopStopwatch() {
        guard let start = stopwatchStart else { return }
        stopwatchAccumulated += Date.now.timeIntervalSince(start)
        stopwatchStart = nil
    }

    func lap() { laps.insert(stopwatchElapsed(), at: 0) }

    func resetStopwatch() {
        stopwatchStart = nil
        stopwatchAccumulated = 0
        laps = []
    }

    static func format(_ t: TimeInterval, tenths: Bool = true) -> String {
        let total = max(0, t)
        let h = Int(total) / 3600, m = Int(total) / 60 % 60, s = Int(total) % 60
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
        return tenths ? base + String(format: ".%d", Int((total * 10).truncatingRemainder(dividingBy: 10))) : base
    }
}
