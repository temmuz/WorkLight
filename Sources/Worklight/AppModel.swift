import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications
import WorklightCore

struct SavedState: Codable {
    var timer: WorkTimer
    var preferences: Preferences
    var targetNotifiedDays: Set<String>
    var reminder: ReminderClock? = nil
}

@MainActor
final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var engine = WorkTimer()
    @Published var preferences = Preferences()
    @Published var now = Date()
    @Published var pulseLit = false
    @Published var isAway = false
    @Published var notificationStatus = "Checking notification permission…"
    @Published var storageError: String?
    @Published var returnPromptVisible = false
    @Published private(set) var resumeReminderDue = false
    @Published private(set) var reminderStatus = "Start a work session to enable paused reminders."
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginAvailable = true
    @Published private(set) var launchAtLoginStatus = "Checking login item…"
    var showReturn: (() -> Void)?
    var dismissPrompt: (() -> Void)?
    var showFallbackReminder: (() -> Void)?
    var showFallbackTarget: (() -> Void)?
    var showSettings: (() -> Void)?
    var showMenu: (() -> Void)?
    var onTick: (() -> Void)?
    private var reminder = ReminderClock()
    private var ticker: Timer?
    private var presence: PresenceMonitor?
    private var lastUptime = ProcessInfo.processInfo.systemUptime
    private var saveTicks = 0
    private var notificationCheckTicks = 0
    private var targetNotifiedDays: Set<String> = []
    private var notificationsAllowed = false
    private var restoredPaused = false
    private var testPulseUntil: Date?
    private let managesLoginItem: Bool
    let stateURL: URL

    override init() {
        let args = ProcessInfo.processInfo.arguments
        managesLoginItem = !args.contains("--data-dir")
        if let i = args.firstIndex(of: "--data-dir"), args.count > i + 1 {
            stateURL = URL(fileURLWithPath: args[i + 1]).appendingPathComponent("state.json")
        } else {
            stateURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Worklight/state.json")
        }
        super.init()
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let data = try Data(contentsOf: stateURL)
                let saved = try JSONDecoder().decode(SavedState.self, from: data)
                engine = saved.timer
                preferences = saved.preferences
                targetNotifiedDays = saved.targetNotifiedDays
                engine.recoverAfterLaunch(at: now)
                reminder = saved.reminder ?? ReminderClock()
                restoredPaused = engine.mode == .paused
            }
        } catch {
            // Keep damaged data intact for recovery; never overwrite it silently.
            storageError = "Your saved timer could not be read. The original file has been kept. Quit and recover it before tracking more work."
        }
    }

    var total: Double { engine.total(on: now, now: now) }
    var target: Double { preferences.targetHours * 3600 }
    var progress: Double { min(1, total / max(1, target)) }
    var isRunning: Bool { engine.mode == .working && engine.activeStart != nil }
    var caption: String {
        if let until = testPulseUntil, until > now { return "REMINDER TEST" }
        if engine.awayStart != nil { return "AWAY · REVIEW TIME" }
        if engine.mode == .finished { return "DONE FOR TODAY" }
        if total >= target { return "DAILY TARGET REACHED" }
        if isRunning { return "TODAY · WORKING" }
        if resumeReminderDue { return "PAUSED · RESUME WORK?" }
        if !engine.startedDays.contains(WorkTimer.dayKey(now)) { return "READY WHEN YOU ARE" }
        if restoredPaused { return "PAUSED · READY TO RESUME" }
        return "TODAY · ON BREAK"
    }

    func launch() {
        configureNotifications()
        refreshLaunchAtLoginStatus()
        let monitor = PresenceMonitor()
        presence = monitor
        isAway = monitor.isAway
        monitor.onChange = { [weak self] away, trackAway in
            MainActor.assumeIsolated { self?.presenceChanged(away: away, trackAway: trackAway) }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        updateReminderStatus()
        if engine.awaitingReturnDecision && !isAway { presentReturn() }
    }

    private func tick() {
        now = Date()
        engine.refreshDay(at: now)
        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0, uptime - lastUptime)
        lastUptime = uptime
        let eligible = engine.remindersEligible(at: now, isAway: isAway, hasStorageError: storageError != nil)
        reminder.advance(by: elapsed, eligible: eligible, now: now)
        resumeReminderDue = eligible && reminder.shouldPulse(after: preferences.pulseMinutes * 60, now: now)
        let testing = !isAway && (testPulseUntil ?? .distantPast) > now
        pulseLit = (resumeReminderDue || testing) && Int(uptime) % 4 < 2
        updateReminderStatus()
        if eligible && reminder.takeNotification(after: preferences.notificationMinutes * 60) {
            sendReminder()
        }
        let day = WorkTimer.dayKey(now)
        if isRunning && !isAway && total >= target && !targetNotifiedDays.contains(day) {
            targetNotifiedDays.insert(day)
            sendTarget()
            save()
        }
        saveTicks += 1
        if saveTicks >= 15 { saveTicks = 0; save() }
        notificationCheckTicks += 1
        if notificationCheckTicks >= 60 { notificationCheckTicks = 0; refreshNotificationStatus() }
        onTick?()
    }

    private func presenceChanged(away: Bool, trackAway: Bool) {
        now = Date()
        isAway = away
        // Sleep alone silences reminders. Only lock/lid events classify away time.
        if trackAway { engine.leave(at: now) }
        if away {
            pulseLit = false
            resumeReminderDue = false
            testPulseUntil = nil
            returnPromptVisible = false
            dismissPrompt?()
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["paused"])
        } else {
            engine.returnToMac(at: now)
            if engine.awaitingReturnDecision { presentReturn() }
        }
        lastUptime = ProcessInfo.processInfo.systemUptime
        save()
    }

    func toggle() {
        guard storageError == nil else { showSettings?(); return }
        if engine.awayStart != nil {
            if !isAway { engine.returnToMac(at: Date()); presentReturn() }
            return
        }
        now = Date()
        if isRunning { engine.pause(at: now) } else { engine.start(at: now) }
        restoredPaused = false
        resetReminder()
        save()
    }

    func resume() {
        guard storageError == nil else { return }
        if engine.awayStart != nil { presentReturn(); return }
        now = Date()
        engine.start(at: now)
        restoredPaused = false
        resetReminder()
        dismissPrompt?()
        save()
    }

    func finish() {
        guard storageError == nil else { return }
        now = Date()
        engine.finish(at: now)
        resetReminder()
        returnPromptVisible = false
        dismissPrompt?()
        save()
    }

    func resolve(_ choice: ReturnChoice) {
        now = Date()
        engine.resolveReturn(choice, at: now)
        restoredPaused = false
        returnPromptVisible = false
        resetReminder()
        dismissPrompt?()
        save()
    }

    func snooze() {
        now = Date()
        reminder.snooze(until: now.addingTimeInterval(600))
        testPulseUntil = nil
        lastUptime = ProcessInfo.processInfo.systemUptime
        pulseLit = false
        resumeReminderDue = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["paused"])
        dismissPrompt?()
        updateReminderStatus()
        save()
    }

    private func resetReminder() {
        reminder.reset()
        pulseLit = false
        resumeReminderDue = false
        testPulseUntil = nil
        lastUptime = ProcessInfo.processInfo.systemUptime
        updateReminderStatus()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["paused", "target"])
    }

    func presentReturn() {
        guard !isAway, engine.awaitingReturnDecision else { return }
        returnPromptVisible = true
        showReturn?()
    }

    func applyPreferences(_ value: Preferences) {
        preferences = value
        updateReminderStatus()
        save()
    }

    func refreshLaunchAtLoginStatus() {
        guard managesLoginItem else {
            launchAtLoginAvailable = false
            launchAtLoginEnabled = false
            launchAtLoginStatus = "Launch at Login is disabled for isolated preview sessions."
            return
        }

        launchAtLoginAvailable = true
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginStatus = "Worklight will open automatically when you sign in."
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "Approval is required in System Settings → General → Login Items."
        case .notFound:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "Move Worklight to Applications, then enable Launch at Login."
        case .notRegistered:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "Worklight will stay closed when you sign in."
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginStatus = "Launch at Login status is unavailable."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard managesLoginItem else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status == .requiresApproval {
                    openLoginItemSettings()
                } else if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginStatus = "Could not update Launch at Login: \(error.localizedDescription)"
        }
    }

    func openLoginItemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func adjust(minutes: Double) {
        guard storageError == nil else { return }
        now = Date()
        engine.adjustToday(by: minutes * 60, at: now)
        save()
    }

    func save() {
        guard storageError == nil else { return }
        engine.checkpoint(at: Date())
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SavedState(timer: engine, preferences: preferences, targetNotifiedDays: targetNotifiedDays, reminder: reminder))
            try data.write(to: stateURL, options: .atomic)
        } catch {
            storageError = "Worklight could not save your time: \(error.localizedDescription)"
        }
    }

    func prepareToQuit() {
        if engine.mode == .working && engine.awayStart == nil { engine.pause(at: Date()) }
        save()
    }

    private func updateReminderStatus() {
        if (testPulseUntil ?? .distantPast) > now {
            reminderStatus = "Testing the pulse for 10 seconds."
        } else if engine.mode == .finished {
            reminderStatus = "Reminders off · day finished."
        } else if engine.awayStart != nil {
            reminderStatus = "Review your away time to continue."
        } else if isAway {
            reminderStatus = "Reminders quiet while your Mac is locked, asleep, or lid-closed."
        } else if isRunning {
            reminderStatus = "Counting work · no resume reminder needed."
        } else if !engine.startedDays.contains(WorkTimer.dayKey(now)) {
            reminderStatus = "Start a work session to enable paused reminders."
        } else if reminder.snoozeRemaining(at: now) > 0 {
            reminderStatus = "Reminders snoozed · \(clockString(reminder.snoozeRemaining(at: now))) remaining."
        } else if resumeReminderDue {
            reminderStatus = "Resume reminder active · resume, snooze, or finish your day."
        } else {
            reminderStatus = "Pulse in \(clockString(max(0, preferences.pulseMinutes * 60 - reminder.elapsedSeconds))) · notification after \(String(format: "%g", preferences.notificationMinutes)) min paused."
        }
    }

    func testReminder() {
        guard !isAway else { return }
        now = Date()
        testPulseUntil = now.addingTimeInterval(10)
        pulseLit = true
        updateReminderStatus()
        if notificationsAllowed {
            notify(id: "test", title: "Worklight reminder test", body: "Your reminder banner is working. The timer is also pulsing for 10 seconds.", category: "")
        }
    }

    func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "PAUSED", actions: [
                UNNotificationAction(identifier: "RESUME", title: "Resume work"),
                UNNotificationAction(identifier: "SNOOZE", title: "Snooze 10 min")
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "TARGET", actions: [
                UNNotificationAction(identifier: "FINISH", title: "Finish day")
            ], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.notificationsAllowed = granted
                self?.notificationStatus = granted
                    ? "Notifications enabled. Focus settings may silence banners."
                    : "Notifications off. Worklight will show a small in-app reminder instead."
            }
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                self?.notificationsAllowed = allowed
                self?.notificationStatus = allowed
                    ? "Notifications enabled. Focus settings may silence banners."
                    : "Notifications off. Worklight will show a small in-app reminder instead."
            }
        }
    }

    private func sendReminder() {
        guard notificationsAllowed else { showFallbackReminder?(); return }
        notify(id: "paused", title: "Back at work?", body: "Your work timer is paused. Resume it, or snooze for 10 minutes.", category: "PAUSED")
    }

    private func sendTarget() {
        guard notificationsAllowed else { showFallbackTarget?(); return }
        notify(id: "target", title: "Your daily target is reached", body: "You’ve worked \(String(format: "%g", preferences.targetHours)) hours today. A good moment to wrap up.", category: "TARGET")
    }

    private func notify(id: String, title: String, body: String, category: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.categoryIdentifier = category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                if id == "paused" { self?.showFallbackReminder?() }
                else if id == "target" { self?.showFallbackTarget?() }
                else { self?.showSettings?() }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let identifier = response.notification.request.identifier
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch action {
            case "RESUME": self.resume()
            case "SNOOZE": self.snooze()
            case "FINISH": self.finish()
            case UNNotificationDefaultActionIdentifier:
                if identifier == "paused" { self.showFallbackReminder?() }
                else { self.showSettings?() }
            default: break
            }
        }
        completionHandler()
    }
}
