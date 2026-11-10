import AppKit
import SwiftUI
import WorklightCore

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var pill: FloatingPanel!
    private var pulseHalo: FloatingPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var prompt: NSPanel?
    private var repositioning = false
    private var defaults: UserDefaults {
        ProcessInfo.processInfo.arguments.contains("--data-dir")
            ? UserDefaults(suiteName: "app.worklight.preview")! : .standard
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu-bar app: no Dock tile and no accidental activation on timer clicks.
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Worklight")
        appMenu.addItem(withTitle: "Today & settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Worklight", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
        pulseHalo = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 266, height: 128),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pulseHalo.title = "Worklight reminder glow"
        pulseHalo.level = .floating
        pulseHalo.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        pulseHalo.isFloatingPanel = true
        pulseHalo.hidesOnDeactivate = false
        pulseHalo.isOpaque = false
        pulseHalo.backgroundColor = .clear
        pulseHalo.hasShadow = false
        pulseHalo.ignoresMouseEvents = true
        pulseHalo.animationBehavior = .none
        pulseHalo.contentView = NSHostingView(rootView: PulseHaloView(model: model))
        pill = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 202, height: 64),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pill.title = "Worklight timer"
        pill.identifier = .init("WorklightPill")
        pill.level = .floating
        pill.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        pill.isFloatingPanel = true
        pill.hidesOnDeactivate = false
        pill.isOpaque = false
        pill.backgroundColor = .clear
        pill.hasShadow = true
        pill.animationBehavior = .none
        pill.contentView = FirstClickHostingView(rootView: PillView(model: model))
        pill.delegate = self
        placePill()
        pulseHalo.orderFrontRegardless()
        pill.orderFrontRegardless()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "WorklightStatusItem"
        statusItem.isVisible = true
        statusItem.button?.image = NSImage(systemSymbolName: "stopwatch", accessibilityDescription: "Worklight")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(openStatusMenu)
        model.showMenu = { [weak self] in self?.openPillMenu() }
        model.showReturn = { [weak self] in self?.showPrompt(.returned) }
        model.dismissPrompt = { [weak self] in self?.prompt?.orderOut(nil) }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.showFallbackReminder = { [weak self] in self?.showPrompt(.reminder) }
        model.showFallbackTarget = { [weak self] in self?.showPrompt(.target) }
        model.onTick = { [weak self] in
            guard let self else { return }
            self.statusItem.button?.toolTip = "Worklight · \(clockString(self.model.total)) · \(self.model.caption.lowercased())"
            self.statusItem.button?.image = NSImage(systemSymbolName: self.model.pulseLit ? "exclamationmark.circle.fill" : "stopwatch", accessibilityDescription: self.model.resumeReminderDue ? "Worklight · resume reminder" : "Worklight")
            self.statusItem.button?.image?.isTemplate = true
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        model.launch()
        if !defaults.bool(forKey: "hasLaunched") {
            defaults.set(true, forKey: "hasLaunched")
            openSettings()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let heading = NSMenuItem(title: "Today  \(clockString(model.total)) / \(String(format: "%g", model.preferences.targetHours))h", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        add(menu, model.engine.awayStart != nil ? "Review away time…" : model.isRunning ? "Pause work" : "Start / resume work", #selector(toggle))
        add(menu, "Snooze reminders for 10 min", #selector(snooze), enabled: model.engine.mode == .paused)
        add(menu, "Finish day", #selector(finish), enabled: model.engine.mode != .finished && model.engine.awayStart == nil)
        menu.addItem(.separator())
        add(menu, "Today & settings…", #selector(openSettings), key: ",")
        add(menu, "Move timer to bottom-right", #selector(resetPosition))
        menu.addItem(.separator())
        add(menu, "Quit Worklight", #selector(quit), key: "q")
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func openStatusMenu() {
        statusItem.menu = makeMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func openPillMenu() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: pill.frame.maxX - 12, y: pill.frame.maxY + 5), in: nil)
    }

    @objc private func toggle() { model.toggle() }
    @objc private func snooze() { model.snooze() }
    @objc private func finish() { model.finish() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 610),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Worklight"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView(model: model))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showPrompt(_ kind: PromptKind) {
        guard !model.isAway else { return }
        // Away-time classification always takes priority over gentle nudges.
        if model.engine.awaitingReturnDecision && kind != .returned { return }
        prompt?.orderOut(nil)
        let hosting = FirstClickHostingView(rootView: PromptView(model: model, kind: kind))
        let size = hosting.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "Worklight"
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = hosting
        p.setContentSize(size)
        if let s = NSScreen.screens.first {
            let f = s.visibleFrame
            let y = min(f.maxY - p.frame.height - 12, pill.frame.maxY + 12)
            p.setFrameOrigin(NSPoint(x: max(f.minX + 12, min(pill.frame.maxX - p.frame.width, f.maxX - p.frame.width - 12)), y: max(f.minY + 12, y)))
        }
        prompt = p
        // Draw attention without taking keyboard focus away from another app.
        p.orderFrontRegardless()
    }

    private func placePill() {
        guard let screen = NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let right = defaults.object(forKey: "rightInset") as? Double ?? 18
        let bottom = defaults.object(forKey: "bottomInset") as? Double ?? 18
        let x = max(frame.minX + 4, min(frame.maxX - 206, frame.maxX - 202 - right))
        let y = max(frame.minY + 4, min(frame.maxY - 68, frame.minY + bottom))
        repositioning = true
        pill.setFrameOrigin(NSPoint(x: x, y: y))
        repositioning = false
        placeHalo()
    }

    func windowDidMove(_ notification: Notification) {
        guard !repositioning, let w = notification.object as? NSWindow, w == pill,
              let screen = NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        let x = max(f.minX + 4, min(f.maxX - pill.frame.width - 4, pill.frame.minX))
        let y = max(f.minY + 4, min(f.maxY - pill.frame.height - 4, pill.frame.minY))
        repositioning = true
        pill.setFrameOrigin(NSPoint(x: x, y: y))
        repositioning = false
        placeHalo()
        defaults.set(f.maxX - pill.frame.maxX, forKey: "rightInset")
        defaults.set(pill.frame.minY - f.minY, forKey: "bottomInset")
    }

    @objc private func resetPosition() {
        defaults.removeObject(forKey: "rightInset")
        defaults.removeObject(forKey: "bottomInset")
        placePill()
    }
    @objc private func displaysChanged() { placePill() }
    private func placeHalo() {
        pulseHalo?.setFrameOrigin(NSPoint(x: pill.frame.minX - 32, y: pill.frame.minY - 32))
    }
    @objc private func spaceChanged() { pulseHalo.orderFrontRegardless(); pill.orderFrontRegardless() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshNotificationStatus()
        model.refreshLaunchAtLoginStatus()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { model.prepareToQuit() }
}

@main
enum WorklightMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
