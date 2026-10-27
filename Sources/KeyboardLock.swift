import AppKit

/// Locks the keyboard for 30 seconds so it can be wiped clean. Keys, modifiers and media keys are swallowed;
/// the trackpad keeps working (the panel has an "Unlock" button). Needs Accessibility. If Nook quits, the
/// lock goes with it.
final class KeyboardLock: ObservableObject {
    static let duration: TimeInterval = 30

    @Published private(set) var until: Date?
    var isLocked: Bool { until != nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?

    /// False without Accessibility (macOS then asks for it).
    @discardableResult
    func lock() -> Bool {
        guard !isLocked else { return true }
        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return false
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        var mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        mask |= CGEventMask(1) << CGEventMask(NX_SYSDEFINED)   // volume, brightness, media keys
        let callback: CGEventTapCallBack = { _, type, event, info in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let info {
                let lock = Unmanaged<KeyboardLock>.fromOpaque(info).takeUnretainedValue()
                if let tap = lock.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return nil
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        source = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        until = Date().addingTimeInterval(Self.duration)
        timer = Timer.scheduledTimer(withTimeInterval: Self.duration, repeats: false) { [weak self] _ in self?.unlock() }
        return true
    }

    func unlock() {
        timer?.invalidate()
        timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        until = nil
    }

    deinit { unlock() }
}
