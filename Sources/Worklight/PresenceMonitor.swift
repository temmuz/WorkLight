import AppKit
import IOKit
import IOKit.pwr_mgt

// No event tap, key logging, screen recording or accessibility permission.
// Paused reminders use lock, sleep and lid state; reading requires no input.
final class PresenceMonitor: NSObject {
    var onChange: ((Bool, Bool) -> Void)?
    private var locked = false
    private var lidClosed = false
    private var sleeping = false
    private var port: IONotificationPortRef?
    private var root: io_service_t = 0
    private var notifier: io_object_t = 0
    private var poll: Timer?

    var isAway: Bool { locked || lidClosed || sleeping }

    override init() {
        super.init()
        let d = DistributedNotificationCenter.default()
        d.addObserver(self, selector: #selector(didLock), name: .init("com.apple.screenIsLocked"), object: nil)
        d.addObserver(self, selector: #selector(didUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)
        let w = NSWorkspace.shared.notificationCenter
        w.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        w.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        w.addObserver(self, selector: #selector(didLock), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        w.addObserver(self, selector: #selector(didUnlock), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)

        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        lidClosed = readLid()
        port = IONotificationPortCreate(kIOMainPortDefault)
        if let port, root != 0, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { context, _, _, _ in
                guard let context else { return }
                let monitor = Unmanaged<PresenceMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.syncLid()
            }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
        }
        // Also refresh after hot-plug and wake; IOKit notifications are primary.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.syncLid() }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func readLid() -> Bool {
        guard root != 0,
              let property = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return false }
        return (property as? Bool) ?? false
    }

    private func syncLid() {
        let value = readLid()
        guard value != lidClosed else { return }
        lidClosed = value
        changed()
    }

    private func changed() { onChange?(isAway, locked || lidClosed) }
    @objc private func didLock() { locked = true; changed() }
    @objc private func didUnlock() { locked = false; lidClosed = readLid(); changed() }
    @objc private func willSleep() { sleeping = true; lidClosed = readLid(); changed() }
    @objc private func didWake() { sleeping = false; lidClosed = readLid(); changed() }

    deinit {
        poll?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if notifier != 0 { IOObjectRelease(notifier) }
        if root != 0 { IOObjectRelease(root) }
        if let port { IONotificationPortDestroy(port) }
    }
}
