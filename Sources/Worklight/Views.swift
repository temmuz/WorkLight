import AppKit
import SwiftUI
import WorklightCore

private let yellow = Color(red: 1, green: 0.81, blue: 0.27)
private let ink = Color(red: 0.10, green: 0.11, blue: 0.13)

// Explicitly use the stable property-wrapper API, including on SDKs that also
// export a State macro whose plugin may not ship with Command Line Tools.
private typealias LocalState<Value> = SwiftUI.State<Value>

struct PulseHaloView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(yellow.opacity(model.pulseLit ? 0.62 : 0))
                .frame(width: 214, height: 76)
                .blur(radius: model.pulseLit ? 14 : 5)
                .scaleEffect(model.pulseLit ? 1.09 : 0.94)
            RoundedRectangle(cornerRadius: 23)
                .stroke(yellow.opacity(model.pulseLit ? 0.72 : 0), lineWidth: 2)
                .frame(width: 222, height: 84)
                .blur(radius: 1.5)
                .scaleEffect(model.pulseLit ? 1.10 : 0.94)
        }
        .frame(width: 266, height: 128)
        .animation(reduceMotion ? nil : .easeInOut(duration: 1.15), value: model.pulseLit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct DragArea: NSViewRepresentable {
    final class Grip: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ nsView: Grip, context: Context) {}
}

struct PillView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LocalState private var menuHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button(action: model.toggle) {
                    Image(systemName: model.engine.awayStart != nil ? "questionmark" : model.isRunning ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(ink)
                        .frame(width: 27, height: 27)
                        .background(yellow, in: Circle())
                }
                .buttonStyle(.plain)
                .help(model.engine.awayStart != nil ? "Review your away time" : model.isRunning ? "Pause work" : "Start or resume work")
                .accessibilityLabel(model.isRunning ? "Pause work" : "Start or resume work")
                VStack(alignment: .leading, spacing: 2) {
                    Text(clockString(model.total))
                        .font(.system(size: 19, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                    Text(model.storageError != nil ? "SAVE ERROR · OPEN SETTINGS" : model.caption)
                        .font(.system(size: 7.5, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(model.isRunning ? Color.white.opacity(0.55) : yellow.opacity(0.9))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(DragArea().help("Drag to move the timer on your main display"))
                Button { model.showMenu?() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(menuHovered ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { menuHovered = $0 }
                .help("Worklight menu")
                .accessibilityLabel("Worklight menu")
                .accessibilityIdentifier("WorklightMenuButton")
            }
            .padding(.leading, 11)
            .padding(.trailing, 3)
            .padding(.top, 8)
            .padding(.bottom, 5)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Color.white.opacity(0.08)
                    yellow.opacity(model.engine.mode == .finished ? 0.4 : 0.85)
                        .frame(width: g.size.width * model.progress)
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 13)
            .padding(.bottom, 7)
        }
        .frame(width: 202, height: 64)
        .background(model.pulseLit ? Color(red: 0.48, green: 0.34, blue: 0.06) : ink)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(model.pulseLit ? yellow : Color.white.opacity(0.14), lineWidth: 1))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: model.pulseLit)
        .preferredColorScheme(.dark)
    }
}

enum PromptKind { case returned, reminder, target }

struct PromptView: View {
    @ObservedObject var model: AppModel
    let kind: PromptKind
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: kind == .target ? "checkmark.circle" : "cup.and.saucer")
                    .foregroundStyle(yellow).font(.system(size: 22))
                Spacer()
                Text("WORKLIGHT").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
            }
            Text(title).font(.system(size: 23, weight: .semibold))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if kind == .returned {
                action("That was a break · resume work", primary: true) { model.resolve(.breakAndResume) }
                action("That was work · continue") { model.resolve(.workAndContinue) }
                Button("Still on break") { model.resolve(.stillOnBreak) }.buttonStyle(.plain).foregroundStyle(.secondary)
            } else if kind == .reminder {
                action("Resume work", primary: true, model.resume)
                Button("Snooze for 10 minutes", action: model.snooze).buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                action("Finish my day", primary: true, model.finish)
                Button("Keep working") { model.dismissPrompt?() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(23)
        .frame(width: 326)
        .background(ink)
        .preferredColorScheme(.dark)
    }
    private var title: String {
        switch kind {
        case .returned: return "Welcome back."
        case .reminder: return "Back at work?"
        case .target: return "You’ve put in your time."
        }
    }
    private var message: String {
        switch kind {
        case .returned:
            let seconds = max(0, (model.engine.returnedAt ?? model.now).timeIntervalSince(model.engine.awayStart ?? model.now))
            let minutes = max(1, Int(seconds / 60))
            return "Your Mac was locked or its lid was closed for about \(minutes) minute\(minutes == 1 ? "" : "s"). Should that time count as work?"
        case .reminder: return "You’re using your Mac, but your work timer is paused. Ready to count your time again?"
        case .target: return "You’ve reached your \(String(format: "%g", model.preferences.targetHours))-hour target today. Wrap up when you’re ready."
        }
    }
    private func action(_ title: String, primary: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
                .foregroundStyle(primary ? ink : .white)
                .background(primary ? yellow : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @LocalState private var correction = ""
    @LocalState private var correctionMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                HStack {
                    Text("TODAY").font(.system(size: 11, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.now, format: .dateTime.day().month(.wide)).foregroundStyle(.secondary).font(.system(size: 12))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(clockString(model.total)).font(.system(size: 43, weight: .light, design: .monospaced))
                    ProgressView(value: model.progress).tint(.orange)
                    HStack {
                        Text(model.caption.lowercased()).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(String(format: "%g", model.preferences.targetHours))h target").foregroundStyle(.secondary)
                    }.font(.system(size: 11))
                }
                HStack {
                    Button(model.engine.awayStart != nil ? "Review away time" : model.isRunning ? "Pause work" : "Start / resume work", action: model.toggle)
                        .buttonStyle(.borderedProminent).tint(.orange)
                    Button("Finish day", action: model.finish).disabled(model.engine.mode == .finished || model.engine.awayStart != nil)
                }
                Text(model.reminderStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("Forgot a pause or resume?").font(.headline)
                    Text("Add minutes you missed, or subtract time that wasn’t work. Your sessions stay intact.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack {
                        TextField("e.g. −20 or +10", text: $correction).frame(width: 135)
                            .accessibilityLabel("Time correction in minutes")
                        Text("minutes").foregroundStyle(.secondary)
                        Spacer()
                        Button("Apply correction") {
                            guard let number = parseNumber(correction) else { return }
                            model.adjust(minutes: number)
                            correction = ""
                            correctionMessage = "Today’s total updated."
                        }.disabled(parseNumber(correction) == nil || model.storageError != nil)
                    }
                    if !correctionMessage.isEmpty { Text(correctionMessage).font(.caption).foregroundStyle(.secondary) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 11) {
                    Text("Last 7 days").font(.headline)
                    ForEach(0..<7, id: \.self) { offset in
                        let date = Calendar.current.date(byAdding: .day, value: -offset, to: model.now)!
                        let seconds = model.engine.total(on: date, now: model.now)
                        HStack {
                            Text(offset == 0 ? "Today" : date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(clockString(seconds)).monospacedDigit()
                        }.font(.system(size: 12))
                    }
                }
                Text("Drag the timer by its numbers. Use its ••• menu for settings, snooze, or finishing your day.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
}

func parseNumber(_ string: String) -> Double? {
    let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
    guard let n = Double(cleaned), n.isFinite else { return nil }
    return n
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @LocalState private var hours = ""
    @LocalState private var pulse = ""
    @LocalState private var notification = ""
    @LocalState private var saved = false
    private var valid: Bool {
        guard let h = parseNumber(hours), let p = parseNumber(pulse), let n = parseNumber(notification) else { return false }
        return h >= 0.25 && h <= 24 && p >= 0.25 && p <= 60 && n >= p && n <= 120
    }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Daily target") {
                    field("Work time", text: $hours, unit: "hours")
                    Text("A gentle alert when you reach your target. The timer continues until you pause or finish.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("While paused with your Mac awake and unlocked") {
                    field("Start gentle pulses after", text: $pulse, unit: "minutes")
                    field("Show a notification after", text: $notification, unit: "minutes")
                    Text("Reading counts too: mouse and keyboard activity are not required. Once due, a gentle pulse repeats until you resume, snooze, or finish your day. Notifications repeat after another 10 eligible paused minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.reminderStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Test reminder", action: model.testReminder)
                }
                Section("Notifications") {
                    Text(model.notificationStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Open macOS notification settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
                Section("Startup") {
                    Toggle("Launch Worklight at login", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    .disabled(!model.launchAtLoginAvailable)
                    Text(model.launchAtLoginStatus).font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items settings", action: model.openLoginItemSettings)
                        .disabled(!model.launchAtLoginAvailable)
                }
                Section("Made for a small corner of your day") {
                    Text("The timer stays on your primary display across desktops. Locking your screen or closing your lid triggers an away-time review. Finish day silences reminders until you start again.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Your timer data stays on this Mac. No accounts or network connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                if saved { Text("Settings saved.").font(.caption).foregroundStyle(.secondary) }
                else if !valid { Text("Use a target of 0.25–24h; notification delay must follow the pulse.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Save settings") {
                    var p = Preferences()
                    p.targetHours = parseNumber(hours)!
                    p.pulseMinutes = parseNumber(pulse)!
                    p.notificationMinutes = parseNumber(notification)!
                    model.applyPreferences(p)
                    saved = true
                }.buttonStyle(.borderedProminent).disabled(!valid || model.storageError != nil)
            }.padding(16)
        }
        .onAppear {
            hours = String(format: "%g", model.preferences.targetHours)
            pulse = String(format: "%g", model.preferences.pulseMinutes)
            notification = String(format: "%g", model.preferences.notificationMinutes)
        }
        .onChange(of: hours) { _ in saved = false }
        .onChange(of: pulse) { _ in saved = false }
        .onChange(of: notification) { _ in saved = false }
    }
    private func field(_ title: String, text: Binding<String>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", text: text).multilineTextAlignment(.trailing).frame(width: 58).accessibilityLabel(title)
            Text(unit).foregroundStyle(.secondary).frame(width: 45, alignment: .leading)
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            if let error = model.storageError {
                Text(error).font(.callout).padding(16).foregroundStyle(.red).frame(maxWidth: .infinity).background(Color.red.opacity(0.08))
            }
            TabView {
                DashboardView(model: model).tabItem { Label("Today", systemImage: "stopwatch") }
                SettingsView(model: model).tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            }.padding(12)
        }.frame(width: 500, height: 610)
    }
}
