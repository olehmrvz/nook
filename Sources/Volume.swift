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
    /// Lowered for dictation: the level before, the level set, and on which device. Kept while the level fades back,
    /// so a new press in that time goes down again from where it is and still comes back to `from`.
    private var ducked: (from: Float, to: Float, device: AudioObjectID)?
    /// The fade that runs now: down for dictation or back up after it.
    private var fade: (timer: Timer, down: Bool)?
    private static let fadeDown: TimeInterval = 0.3
    private static let fadeUp: TimeInterval = 0.4
    /// Nook's own change is not shown in the notch.
    private var silentUntil: Date?

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
        restoreAfterCrash()
        // Quitting while dictation listens (the menu, a restart for a new language, an update): the level comes back.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.restore(fading: false) }
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

    private var current: (level: Float, muted: Bool)? { state(of: device) }

    private func state(of device: AudioObjectID) -> (level: Float, muted: Bool)? {
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
        if let silentUntil, Date() < silentUntil { last = now; return }
        if let last, abs(last.level - now.level) < 0.001, last.muted == now.muted { return }
        last = now
        onChange?(now.level, now.muted)
    }

    // MARK: Ducking

    /// Down to `level` while dictation listens, in a short fade that starts at once; nothing to do when it is already
    /// this low or muted.
    func duck(to level: Float) {
        if let ducked {
            // Still coming back after the last recording: down again from where it is.
            if fade?.down == false { lower(ducked) }
            return
        }
        guard let now = current, !now.muted, now.level > level + 0.001, canSetVolume else { return }
        let lowered = (from: now.level, to: level, device: device)
        ducked = lowered
        save(lowered)
        lower(lowered)
    }

    private func lower(_ lowered: (from: Float, to: Float, device: AudioObjectID)) {
        guard let now = state(of: lowered.device) else { return }
        run(on: lowered.device, from: now.level, to: lowered.to, down: true) { [weak self] in
            // The device may round the level: `restore` compares with the level it really took.
            guard let self, var ducked = self.ducked, let reached = self.state(of: ducked.device) else { return }
            ducked.to = reached.level
            self.ducked = ducked
            self.save(ducked)
        }
    }

    /// Back to the level before on the device that was lowered, also when the output changed in between (AirPods
    /// came in); not when the person set another level on that device. At once, without a fade, when Nook quits.
    func restore(fading: Bool = true) {
        guard let ducked, fade?.down != false || !fading else { return }
        // During a fade the level is Nook's own; after it, only the level Nook left counts.
        let ours = fade != nil || state(of: ducked.device).map { abs($0.level - ducked.to) < 0.01 } == true
        stopFade()
        guard ours, fading, let now = state(of: ducked.device) else {
            if ours { write(ducked.from, on: ducked.device) }
            clearDuck()
            return
        }
        run(on: ducked.device, from: now.level, to: ducked.from, down: false) { [weak self] in self?.clearDuck() }
    }

    private func clearDuck() {
        ducked = nil
        Settings.duckedVolume = nil
    }

    private func save(_ lowered: (from: Float, to: Float, device: AudioObjectID)) {
        guard let uid = Self.uid(of: lowered.device) else { return }
        Settings.duckedVolume = ["from": Double(lowered.from), "to": Double(lowered.to), "uid": uid]
    }

    /// Small steps about 60 times a second, slow at both ends so neither the start nor the stop is heard as a jump.
    /// The timer runs only for the fade.
    private func run(on device: AudioObjectID, from start: Float, to end: Float, down: Bool,
                     then done: @escaping () -> Void) {
        stopFade()
        let began = Date()
        let seconds = down ? Self.fadeDown : Self.fadeUp
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = Float(min(1, Date().timeIntervalSince(began) / seconds))
            self.write(start + (end - start) * t * t * (3 - 2 * t), on: device)
            guard t >= 1 else { return }
            self.stopFade()
            done()
        }
        RunLoop.main.add(timer, forMode: .common)
        fade = (timer, down)
    }

    private func stopFade() {
        fade?.timer.invalidate()
        fade = nil
    }

    /// Nook ended while dictation had the output lowered (a crash, a kill, `install.sh`): the level comes back
    /// at the next start, unless the person changed it since.
    private func restoreAfterCrash() {
        guard let saved = Settings.duckedVolume else { return }
        Settings.duckedVolume = nil
        guard let from = saved["from"] as? Double, let to = saved["to"] as? Double,
              let uid = saved["uid"] as? String, let device = Self.device(uid: uid) else { return }
        set(Float(from), on: device, ifStill: Float(to))
    }

    private func set(_ level: Float, on device: AudioObjectID, ifStill expected: Float) {
        guard let now = state(of: device), abs(now.level - expected) < 0.01 else { return }
        write(level, on: device)
    }

    private func write(_ level: Float, on device: AudioObjectID) {
        var level = level
        if device == self.device { silentUntil = Date().addingTimeInterval(0.5) }
        AudioObjectSetPropertyData(device, &Self.volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &name) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
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
            let target = now.level + (key == NX_KEYTYPE_SOUND_UP ? step : -step)
            var level = max(0, min(1, (target / step).rounded() * step))
            AudioObjectSetPropertyData(device, &Self.volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
            if now.muted {
                var unmuted: UInt32 = 0
                AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &unmuted)
            }
        }
        // A key press shows the level even when it did not change (already at 0 or 100 %).
        if let after = current { last = after; onChange?(after.level, after.muted) }
    }

    /// HDMI or DisplayPort audio, an aggregate device: no level Nook can set, so the keys stay with macOS and
    /// other apps (MonitorControl).
    private var canSetVolume: Bool {
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &Self.volume, &settable) == noErr && settable.boolValue
    }

    /// Nook handles the volume and brightness keys (the macOS HUD stays hidden).
    var hasKeys: Bool { tap != nil }

    /// "Volume and brightness" turned on in Settings: take the keys now, not after a restart.
    func apply() { installKeyTap() }

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
                guard control.canSetVolume else { return Unmanaged.passUnretained(event) }
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
