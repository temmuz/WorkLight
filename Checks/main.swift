import Foundation
import WorklightCore

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "Expected false", file: file, line: line)
}

final class WorkTimerTests {
    let t = Date(timeIntervalSince1970: 1_793_707_200)

    func testSeveralSessionsAccumulate() {
        var timer = WorkTimer()
        timer.start(at: t)
        timer.pause(at: t.addingTimeInterval(600))
        timer.start(at: t.addingTimeInterval(1800))
        timer.pause(at: t.addingTimeInterval(2100))
        expectEqual(timer.total(on: t, now: t.addingTimeInterval(2100)), 900)
    }

    func testBreakExcludesLockAndDecisionTimeWithoutDoubleCounting() {
        var timer = WorkTimer()
        timer.start(at: t)
        timer.leave(at: t.addingTimeInterval(600))
        timer.leave(at: t.addingTimeInterval(601))
        timer.returnToMac(at: t.addingTimeInterval(1800))
        timer.returnToMac(at: t.addingTimeInterval(1802))
        timer.resolveReturn(.breakAndResume, at: t.addingTimeInterval(1810))
        expectEqual(timer.total(on: t, now: t.addingTimeInterval(1870)), 660)
    }

    func testAwayWorkCanBeIncluded() {
        var timer = WorkTimer()
        timer.start(at: t)
        timer.leave(at: t.addingTimeInterval(600))
        timer.returnToMac(at: t.addingTimeInterval(1800))
        timer.resolveReturn(.workAndContinue, at: t.addingTimeInterval(1810))
        expectEqual(timer.total(on: t, now: t.addingTimeInterval(1900)), 1900)
    }

    func testAlreadyPausedStaysPausedAfterLock() {
        var timer = WorkTimer()
        timer.start(at: t)
        timer.pause(at: t.addingTimeInterval(60))
        timer.leave(at: t.addingTimeInterval(70))
        timer.returnToMac(at: t.addingTimeInterval(170))
        expectFalse(timer.awaitingReturnDecision)
        expectEqual(timer.mode, .paused)
    }

    func testStillOnBreakAndFinishedNeverKeepCounting() {
        var timer = WorkTimer()
        timer.start(at: t)
        timer.leave(at: t.addingTimeInterval(60))
        timer.returnToMac(at: t.addingTimeInterval(170))
        timer.resolveReturn(.stillOnBreak, at: t.addingTimeInterval(180))
        expectEqual(timer.mode, .paused)
        timer.finish(at: t.addingTimeInterval(200))
        expectEqual(timer.total(on: t, now: t.addingTimeInterval(3000)), 60)
    }

    func testMidnightSplitsSessionsIntoLocalCalendarDays() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let midnight = cal.startOfDay(for: t)
        var timer = WorkTimer()
        timer.start(at: midnight.addingTimeInterval(-120))
        timer.pause(at: midnight.addingTimeInterval(180))
        expectEqual(timer.total(on: midnight.addingTimeInterval(-1), now: midnight.addingTimeInterval(180), calendar: cal), 120)
        expectEqual(timer.total(on: midnight, now: midnight.addingTimeInterval(180), calendar: cal), 180)
    }

    func testCrashRecoveryAsksAboutUnobservedGapAndSurvivesSerialization() throws {
        var timer = WorkTimer()
        timer.start(at: t)
        timer.checkpoint(at: t.addingTimeInterval(60))
        let data = try JSONEncoder().encode(timer)
        var restored = try JSONDecoder().decode(WorkTimer.self, from: data)
        restored.recoverAfterLaunch(at: t.addingTimeInterval(600))
        expectTrue(restored.awaitingReturnDecision)
        expectEqual(restored.total(on: t, now: t.addingTimeInterval(600)), 60)
        restored.resolveReturn(.breakAndResume, at: t.addingTimeInterval(600))
        expectEqual(restored.total(on: t, now: t.addingTimeInterval(660)), 120)
    }

    func testCorrectionNeverMakesTotalNegative() {
        var timer = WorkTimer()
        timer.start(at: t)
        timer.pause(at: t.addingTimeInterval(60))
        timer.adjustToday(by: -600, at: t.addingTimeInterval(120))
        expectEqual(timer.total(on: t, now: t.addingTimeInterval(120)), 0)
    }

    func testNewDayIsQuietUntilStarted() {
        var timer = WorkTimer()
        timer.start(at: t)
        timer.finish(at: t.addingTimeInterval(60))
        let tomorrow = t.addingTimeInterval(86400)
        timer.refreshDay(at: tomorrow)
        expectEqual(timer.mode, .paused)
        expectFalse(timer.startedDays.contains(WorkTimer.dayKey(tomorrow)))
    }

    func testRemindersOnlyAccumulateEligibleTimeAndSnoozeWorks() {
        var r = ReminderClock()
        for _ in 0..<300 { r.advance(by: 1, eligible: false, now: t) }
        expectEqual(r.elapsedSeconds, 0)
        for _ in 0..<120 { r.advance(by: 1, eligible: true, now: t) }
        expectTrue(r.shouldPulse(after: 120, now: t))
        expectFalse(r.takeNotification(after: 300))
        for _ in 0..<180 { r.advance(by: 1, eligible: true, now: t) }
        expectTrue(r.takeNotification(after: 300))
        expectFalse(r.takeNotification(after: 300))
        r.snooze(until: t.addingTimeInterval(600))
        r.advance(by: 1, eligible: true, now: t.addingTimeInterval(599))
        expectEqual(r.elapsedSeconds, 0)
        r.advance(by: 1, eligible: true, now: t.addingTimeInterval(600))
        expectEqual(r.elapsedSeconds, 0)
        r.advance(by: 1, eligible: true, now: t.addingTimeInterval(601))
        expectEqual(r.elapsedSeconds, 1)
    }

    func testLockingAgainBeforeAnsweringExtendsUncertainInterval() {
        var timer = WorkTimer()
        timer.start(at: t)
        timer.leave(at: t.addingTimeInterval(60))
        timer.returnToMac(at: t.addingTimeInterval(120))
        timer.leave(at: t.addingTimeInterval(150))
        expectFalse(timer.awaitingReturnDecision)
        timer.returnToMac(at: t.addingTimeInterval(300))
        expectEqual(timer.returnedAt, t.addingTimeInterval(300))
        timer.resolveReturn(.breakAndResume, at: t.addingTimeInterval(301))
        expectEqual(timer.total(on: t, now: t.addingTimeInterval(361)), 120)
    }

    func testNotificationRepeatRequiresTenMoreActiveMinutes() {
        var r = ReminderClock()
        for _ in 0..<300 { r.advance(by: 1, eligible: true, now: t) }
        expectTrue(r.takeNotification(after: 300))
        for _ in 0..<599 { r.advance(by: 1, eligible: true, now: t) }
        expectFalse(r.takeNotification(after: 300))
        r.advance(by: 1, eligible: true, now: t)
        expectTrue(r.takeNotification(after: 300))
    }

    func testReadyAndPausedRemindersDoNotRequireKeyboardActivity() {
        var timer = WorkTimer()
        // A new installation must remind even before the very first session.
        expectTrue(timer.remindersEligible(at: t, isAway: false))
        var reminder = ReminderClock()
        reminder.advance(by: 120, eligible: timer.remindersEligible(at: t, isAway: false), now: t)
        expectTrue(reminder.shouldPulse(after: 120, now: t))
        reminder.advance(by: 180, eligible: timer.remindersEligible(at: t, isAway: false), now: t)
        expectTrue(reminder.takeNotification(after: 300))
        timer.start(at: t)
        expectFalse(timer.remindersEligible(at: t, isAway: false))
        timer.pause(at: t.addingTimeInterval(60))
        expectTrue(timer.remindersEligible(at: t.addingTimeInterval(600), isAway: false))
        expectFalse(timer.remindersEligible(at: t, isAway: true))
        expectFalse(timer.remindersEligible(at: t, isAway: false, hasStorageError: true))
        timer.finish(at: t.addingTimeInterval(600))
        expectFalse(timer.remindersEligible(at: t, isAway: false))
        let tomorrow = t.addingTimeInterval(86400)
        timer.refreshDay(at: tomorrow)
        expectTrue(timer.remindersEligible(at: tomorrow, isAway: false))
    }

    func testCoalescedTimerTicksCountAllEligibleTime() {
        var r = ReminderClock()
        r.advance(by: 125, eligible: true, now: t.addingTimeInterval(125))
        expectEqual(r.elapsedSeconds, 125)
        expectTrue(r.shouldPulse(after: 120, now: t.addingTimeInterval(125)))
        r.advance(by: 600, eligible: false, now: t.addingTimeInterval(725))
        expectEqual(r.elapsedSeconds, 125)
    }

    func testPulseContinuesBetweenOldFourSecondWindows() {
        var r = ReminderClock()
        r.advance(by: 120, eligible: true, now: t.addingTimeInterval(120))
        for seconds in [120.0, 125, 150, 179, 180, 239] {
            expectTrue(r.shouldPulse(after: 120, now: t.addingTimeInterval(seconds)))
        }
        r.reset()
        expectFalse(r.shouldPulse(after: 120, now: t.addingTimeInterval(300)))
    }

    func testReminderProgressSurvivesRestart() throws {
        var r = ReminderClock()
        r.advance(by: 90, eligible: true, now: t.addingTimeInterval(90))
        var restored = try JSONDecoder().decode(ReminderClock.self, from: JSONEncoder().encode(r))
        expectEqual(restored.elapsedSeconds, 90)
        restored.advance(by: 30, eligible: true, now: t.addingTimeInterval(1000))
        expectEqual(restored.elapsedSeconds, 120)
        expectTrue(restored.shouldPulse(after: 120, now: t.addingTimeInterval(1000)))
    }

    func testTickAcrossSnoozeBoundaryCountsOnlyUnsnoozedTime() {
        var r = ReminderClock()
        r.snooze(until: t.addingTimeInterval(20))
        r.advance(by: 30, eligible: true, now: t.addingTimeInterval(30))
        expectEqual(r.elapsedSeconds, 10)
    }
}

let checks = WorkTimerTests()
checks.testSeveralSessionsAccumulate()
checks.testBreakExcludesLockAndDecisionTimeWithoutDoubleCounting()
checks.testAwayWorkCanBeIncluded()
checks.testAlreadyPausedStaysPausedAfterLock()
checks.testStillOnBreakAndFinishedNeverKeepCounting()
checks.testMidnightSplitsSessionsIntoLocalCalendarDays()
try checks.testCrashRecoveryAsksAboutUnobservedGapAndSurvivesSerialization()
checks.testCorrectionNeverMakesTotalNegative()
checks.testNewDayIsQuietUntilStarted()
checks.testRemindersOnlyAccumulateEligibleTimeAndSnoozeWorks()
checks.testLockingAgainBeforeAnsweringExtendsUncertainInterval()
checks.testNotificationRepeatRequiresTenMoreActiveMinutes()
checks.testReadyAndPausedRemindersDoNotRequireKeyboardActivity()
checks.testCoalescedTimerTicksCountAllEligibleTime()
checks.testPulseContinuesBetweenOldFourSecondWindows()
try checks.testReminderProgressSurvivesRestart()
checks.testTickAcrossSnoozeBoundaryCountsOnlyUnsnoozedTime()
print("17 work-accounting and reminder checks passed.")
