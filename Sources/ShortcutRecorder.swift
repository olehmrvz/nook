import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A shortcut the person recorded: a key code and Carbon modifiers (what `HotKey` registers), or one modifier
/// key alone (`modifiers == 0` and a modifier key code), which only dictation watches.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let launcher = Shortcut(keyCode: UInt32(kVK_Space), modifiers: HotKey.option)
    static let dictation = Shortcut(keyCode: UInt32(kVK_RightOption), modifiers: 0)

    /// Modifier keys that work alone: key code → their device-dependent flag bit (NX_DEVICE…KEYMASK) and name.
    static let modifierKeys: [UInt32: (mask: UInt64, name: String)] = [
        54: (0x10, "Правый ⌘"), 55: (0x08, "Левый ⌘"), 61: (0x40, "Правый ⌥"), 58: (0x20, "Левый ⌥"),
        62: (0x2000, "Правый ⌃"), 59: (0x01, "Левый ⌃"), 60: (0x04, "Правый ⇧"), 56: (0x02, "Левый ⇧"),
        63: (CGEventFlags.maskSecondaryFn.rawValue, "fn"),
    ]

    /// The flag bit to watch when this is one modifier key alone.
    var modifierMask: UInt64? { modifiers == 0 ? Self.modifierKeys[keyCode]?.mask : nil }
    var isModifierOnly: Bool { modifierMask != nil }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// From `[key code, modifiers]` as kept in the settings.
    init?(stored: [Int]) {
        guard stored.count == 2 else { return nil }
        self.init(keyCode: UInt32(stored[0]), modifiers: UInt32(stored[1]))
    }

    /// F1…F20 work alone; any other key needs ⌘, ⌥ or ⌃ (a bare letter would stop typing everywhere).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= HotKey.command }
        if flags.contains(.option) { carbon |= HotKey.option }
        if flags.contains(.control) { carbon |= HotKey.control }
        if flags.contains(.shift) { carbon |= HotKey.shift }
        let code = UInt32(event.keyCode)
        guard carbon & (HotKey.command | HotKey.option | HotKey.control) != 0 || Self.functionKeys[code] != nil else {
            return nil
        }
        self.init(keyCode: code, modifiers: carbon)
    }

    /// "⌥ Пробел", "⌃⌘K", "F20", "Правый ⌥".
    var title: String {
        if modifiers == 0, let modifier = Self.modifierKeys[keyCode] { return modifier.name }
        var symbols = ""
        if modifiers & HotKey.control != 0 { symbols += "⌃" }
        if modifiers & HotKey.option != 0 { symbols += "⌥" }
        if modifiers & HotKey.shift != 0 { symbols += "⇧" }
        if modifiers & HotKey.command != 0 { symbols += "⌘" }
        let key = Self.keyName(keyCode)
        return symbols.isEmpty ? key : (key.count > 1 ? "\(symbols) \(key)" : symbols + key)
    }

    private static let functionKeys: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let named: [UInt32: String] = [
        49: "Пробел", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    /// The key's letter in the ASCII layout (so ⌥K shows "K", not "Л", with the Russian layout on).
    private static func keyName(_ code: UInt32) -> String {
        if let name = named[code] ?? functionKeys[code] { return name }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// A button that shows the shortcut; click it and press the new combination (Escape cancels).
/// With `modifierAlone`, pressing and releasing one modifier key records that key by itself.
struct ShortcutRecorder: View {
    /// nil: none yet ("Записать").
    let shortcut: Shortcut?
    /// What "Сбросить" goes back to; nil offers "Убрать" instead.
    let fallback: Shortcut?
    var modifierAlone = false
    /// Recording starts or ends: the old shortcut is released meanwhile, so pressing it records instead of firing.
    let onRecording: (Bool) -> Void
    let onChange: (Shortcut?) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    /// A modifier key is down with nothing else yet: released like that, it is the shortcut.
    @State private var lone: UInt16?

    var body: some View {
        HStack(spacing: 8) {
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Нажмите сочетание…" : shortcut?.title ?? "Записать")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(shortcut == nil && !recording ? .secondary : .primary)
                    .frame(minWidth: 130)
            }
            if recording {
                Button("Отмена") { stop() }
            } else if let fallback, shortcut != fallback {
                Button("Сбросить") { onChange(fallback) }
            } else if fallback == nil, shortcut != nil {
                Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Убрать сочетание")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        lone = nil
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                guard modifierAlone, let key = Shortcut.modifierKeys[UInt32(event.keyCode)] else { return nil }
                let down = UInt64(event.modifierFlags.rawValue) & key.mask != 0
                let held = [NSEvent.ModifierFlags.command, .option, .control, .shift].filter { event.modifierFlags.contains($0) }
                if down {
                    // Only the first modifier counts as "alone"; a second one makes it a combination.
                    lone = lone == nil && held.count <= 1 ? event.keyCode : nil
                } else if lone == event.keyCode {
                    onChange(Shortcut(keyCode: UInt32(event.keyCode), modifiers: 0))
                    stop()
                }
                return nil
            }
            lone = nil
            if event.keyCode == UInt16(kVK_Escape) && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()
            } else if let recorded = Shortcut(event: event) {
                onChange(recorded)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        lone = nil
        guard recording else { return }
        recording = false
        onRecording(false)
    }
}
