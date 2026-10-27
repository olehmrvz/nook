import AppKit
import AudioToolbox
import CoreAudio

/// Output volume in the notch. Watches the default output device; with Accessibility access it also takes the
/// volume keys itself, so the macOS volume HUD does not show next to Nook's.
final class VolumeControl {
    /// Level 0…1 and mute, on the main thread, whenever the volume changes (keys, menu bar, another app).
    var onChange: ((Float, Bool) -> Void)?

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

    /// Needs Accessibility; without it the keys stay with macOS and Nook only shows the change.
    private func installKeyTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
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
            guard [NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN, NX_KEYTYPE_MUTE].contains(key) else {
                return Unmanaged.passUnretained(event)
            }
            if down { control.press(key, fine: ns.modifierFlags.contains([.option, .shift])) }
            return nil
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }
}
