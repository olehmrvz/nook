import AppKit
import AudioToolbox
import CoreAudio

/// Volume and brightness in the notch. Watches the default output device; with Accessibility access it also takes
/// the volume and brightness keys itself, so the macOS HUD does not show next to Nook's.
final class VolumeControl {
    /// Level 0…1 and mute, on the main thread, whenever the volume changes (keys, menu bar, another app).
    var onChange: ((Float, Bool) -> Void)?
    /// Built-in display brightness 0…1 after a brightness key (automatic brightness changes show nothing).
    var onBrightness: ((Float) -> Void)?
    private var keyMonitor: Any?
    /// The keyboard lock is on: volume and brightness keys do nothing.
    var isPaused: () -> Bool = { false }

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var last: (level: Float, muted: Bool)?
    private var tap: CFMachPort?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var valueListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var volume = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var mute = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    func start() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attach() }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, .main, listener)
        attach()
        if Settings.volumeHUD { installKeyTap() }
        if tap == nil && Settings.volumeHUD && !Settings.askedKeyAccess {
            // Once: macOS shows its own volume/brightness HUD until Nook may take the keys.
            Settings.askedKeyAccess = true
            askAccess()
        }
        // Access granted later (System Settings): take the keys at once, no restart needed.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.installKeyTap() }
        }
        if tap == nil {
            // No Accessibility: the keys stay with macOS (its HUD shows too); Nook still shows the new brightness.
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
                guard let self, Settings.volumeHUD, event.subtype.rawValue == 8 else { return }
                let key = Int32((event.data1 & 0xFFFF0000) >> 16)
                guard key == NX_KEYTYPE_BRIGHTNESS_UP || key == NX_KEYTYPE_BRIGHTNESS_DOWN,
                      (event.data1 & 0xFF00) >> 8 == 0x0A else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let level = Brightness.level { self.onBrightness?(level) }
                }
            }
        }
    }

    /// Follows the current output (speakers, headphones, AirPods). Switching devices shows nothing.
    private func attach() {
        if let valueListener, device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &Self.volume, .main, valueListener)
            AudioObjectRemovePropertyListenerBlock(device, &Self.mute, .main, valueListener)
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, 0, nil, &size, &id) == noErr
        else { return }
        device = id
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
        valueListener = listener
        AudioObjectAddPropertyListenerBlock(device, &Self.volume, .main, listener)
        AudioObjectAddPropertyListenerBlock(device, &Self.mute, .main, listener)
        last = current
    }

    private var current: (level: Float, muted: Bool)? {
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &Self.volume, 0, nil, &size, &level) == noErr else { return nil }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(device, &Self.mute, 0, nil, &size, &muted)
        return (level, muted != 0)
    }

    private func changed() {
        guard let now = current, Settings.volumeHUD else { return }
        if let last, abs(last.level - now.level) < 0.001, last.muted == now.muted { return }
        last = now
        onChange?(now.level, now.muted)
    }

    // MARK: Volume keys

    /// Steps like macOS: 16 per full range, ⌥⇧ for quarter steps.
    private func press(_ key: Int32, fine: Bool) {
        guard let now = current else { return }
        if key == NX_KEYTYPE_MUTE {
            var muted: UInt32 = now.muted ? 0 : 1
            AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
        } else {
            let step: Float = fine ? 1 / 64 : 1 / 16
            var level = max(0, min(1, (now.level + (key == NX_KEYTYPE_SOUND_UP ? step : -step)) / step).rounded() * step)
            AudioObjectSetPropertyData(device, &Self.volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
            if now.muted {
                var unmuted: UInt32 = 0
                AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &unmuted)
            }
        }
        // A key press shows the level even when it did not change (already at 0 or 100 %).
        if let after = current { last = after; onChange?(after.level, after.muted) }
    }

    /// Nook handles the volume and brightness keys (the macOS HUD stays hidden).
    var hasKeys: Bool { tap != nil }

    func askAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Needs Accessibility; without it the keys stay with macOS and Nook only shows the change.
    private func installKeyTap() {
        guard tap == nil, Settings.volumeHUD, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1) << CGEventMask(NX_SYSDEFINED)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let control = Unmanaged<VolumeControl>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = control.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard Settings.volumeHUD, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }
            let key = Int32((ns.data1 & 0xFFFF0000) >> 16)
            let down = (ns.data1 & 0xFF00) >> 8 == 0x0A
            let media = [NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE, NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN]
            if control.isPaused() && media.contains(key) { return nil }
            let fine = ns.modifierFlags.contains([.option, .shift])
            if [NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE].contains(key) {
                if down { control.press(key, fine: fine) }
                return nil
            }
            // Brightness: only the built-in display; other displays keep the system behaviour.
            if (key == NX_KEYTYPE_BRIGHTNESS_UP || key == NX_KEYTYPE_BRIGHTNESS_DOWN), let level = Brightness.level {
                if down {
                    let step: Float = fine ? 1 / 64 : 1 / 16
                    let next = max(0, min(1, ((level + (key == NX_KEYTYPE_BRIGHTNESS_UP ? step : -step)) / step).rounded() * step))
                    Brightness.set(next)
                    control.onBrightness?(next)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = port
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }
}

/// Built-in display brightness through DisplayServices (private, the same calls Control Center uses).
enum Brightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (UInt32, Float) -> Int32
    private static let framework = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getter = dlsym(framework, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: Get.self) }
    private static let setter = dlsym(framework, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: Set.self) }

    private static var builtIn: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// nil without a built-in display (lid closed, desktop Mac).
    static var level: Float? {
        guard let display = builtIn, let getter else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let display = builtIn, let setter else { return }
        _ = setter(display, value)
    }
}
