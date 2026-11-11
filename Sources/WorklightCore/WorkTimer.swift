import Foundation

public struct WorkInterval: Codable, Equatable {
    public var start: Date
    public var end: Date
}

public enum TimerMode: String, Codable { case paused, working, finished }
public enum ReturnChoice { case breakAndResume, workAndContinue, stillOnBreak }

public struct WorkTimer: Codable {
    public private(set) var mode: TimerMode = .paused
    public private(set) var intervals: [WorkInterval] = []
    public private(set) var adjustments: [String: Double] = [:]
    public private(set) var startedDays: Set<String> = []
    public private(set) var activeStart: Date?
    public private(set) var awayStart: Date?
    public private(set) var returnedAt: Date?
    public private(set) var finishedDay: String?
    public private(set) var lastCheckpoint: Date?

    public init() {}

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public var awaitingReturnDecision: Bool { awayStart != nil && returnedAt != nil }

    public func remindersEligible(at date: Date, isAway: Bool, hasStorageError: Bool = false) -> Bool {
        mode == .paused && awayStart == nil && !isAway && !hasStorageError
    }

    public mutating func refreshDay(at date: Date, calendar: Calendar = .current) {
        if mode == .finished && finishedDay != Self.dayKey(date, calendar: calendar) {
            mode = .paused
            finishedDay = nil
        }
    }

    public mutating func start(at date: Date) {
        guard awayStart == nil else { return }
        if activeStart == nil { activeStart = date }
        mode = .working
        finishedDay = nil
        startedDays.insert(Self.dayKey(date))
    }

    private mutating func commit(until date: Date) {
        if let start = activeStart, date > start {
            intervals.append(WorkInterval(start: start, end: date))
        }
        activeStart = nil
    }

    public mutating func pause(at date: Date) {
        guard awayStart == nil else { return }
        if mode == .working { startedDays.insert(Self.dayKey(date)) }
        commit(until: date)
        mode = .paused
    }

    public mutating func finish(at date: Date) {
        commit(until: date)
        awayStart = nil
        returnedAt = nil
        mode = .finished
        finishedDay = Self.dayKey(date)
    }

    // Multiple lock/lid/sleep signals all refer to the same interval.
    public mutating func leave(at date: Date) {
        guard mode == .working else { return }
        if awayStart != nil {
            returnedAt = nil
            return
        }
        commit(until: date)
        awayStart = date
        returnedAt = nil
    }

    public mutating func returnToMac(at date: Date) {
        guard awayStart != nil, returnedAt == nil else { return }
        returnedAt = date
    }

    public mutating func resolveReturn(_ choice: ReturnChoice, at date: Date) {
        guard let away = awayStart, returnedAt != nil else { return }
        if case .workAndContinue = choice, date > away {
            intervals.append(WorkInterval(start: away, end: date))
        }
        awayStart = nil
        returnedAt = nil
        switch choice {
        case .stillOnBreak: mode = .paused
        case .breakAndResume, .workAndContinue: start(at: date)
        }
    }

    public func total(on date: Date, now: Date, calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        func overlap(_ a: Date, _ b: Date) -> Double {
            max(0, min(b, end).timeIntervalSince(max(a, start)))
        }
        var seconds = intervals.reduce(0) { $0 + overlap($1.start, $1.end) }
        if let active = activeStart { seconds += overlap(active, now) }
        seconds += adjustments[Self.dayKey(date, calendar: calendar), default: 0]
        return max(0, seconds)
    }

    public mutating func adjustToday(by seconds: Double, at date: Date) {
        let key = Self.dayKey(date)
        adjustments[key, default: 0] += max(-total(on: date, now: date), seconds)
    }

    public mutating func checkpoint(at date: Date) { lastCheckpoint = date }

    // A crash/reboot gap is uncertain. Ask about it instead of silently billing it.
    public mutating func recoverAfterLaunch(at date: Date) {
        if let start = activeStart {
            let boundary = max(start, min(lastCheckpoint ?? start, date))
            commit(until: boundary)
            awayStart = boundary
            returnedAt = date
        } else if awayStart != nil {
            returnedAt = date
        }
        refreshDay(at: date)
    }
}

public struct ReminderClock: Codable {
    public private(set) var elapsedSeconds: Double = 0
    private var lastNotification: Double?
    private var snoozedUntil: Date?

    public init() {}
    public mutating func reset() { self = ReminderClock() }
    public mutating func snooze(until date: Date) {
        elapsedSeconds = 0
        lastNotification = nil
        snoozedUntil = date
    }
    public mutating func advance(by seconds: Double, eligible: Bool, now: Date) {
        guard eligible, now >= (snoozedUntil ?? .distantPast) else { return }
        // Count real eligible time even if macOS coalesces background timer ticks.
        // If a tick spans the end of a snooze, count only its unsnoozed portion.
        let start = now.addingTimeInterval(-max(0, seconds))
        let eligibleStart = max(start, snoozedUntil ?? start)
        elapsedSeconds += max(0, now.timeIntervalSince(eligibleStart))
    }
    public func shouldPulse(after threshold: Double, now: Date) -> Bool {
        now >= (snoozedUntil ?? .distantPast) && elapsedSeconds >= threshold
    }
    public func snoozeRemaining(at date: Date) -> Double {
        max(0, (snoozedUntil ?? date).timeIntervalSince(date))
    }
    public mutating func takeNotification(after threshold: Double, repeatEvery: Double = 600) -> Bool {
        guard elapsedSeconds >= threshold,
              lastNotification == nil || elapsedSeconds - lastNotification! >= repeatEvery else { return false }
        lastNotification = elapsedSeconds
        return true
    }
}

public struct Preferences: Codable {
    public var targetHours: Double = 8
    public var pulseMinutes: Double = 2
    public var notificationMinutes: Double = 5
    public init() {}
}

public func clockString(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
