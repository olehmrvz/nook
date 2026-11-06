import AppKit
import Carbon.HIToolbox

/// Window management like Rectangle: halves, quarters, thirds, maximize, center, sizes, displays, restore.
/// Found in the search ("Левая половина"), each with its own shortcut. Needs Accessibility; AX runs off the main thread.
enum WindowAction: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf, centerHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, centerTwoThirds, lastTwoThirds
    case maximize, center, reasonableSize, larger, smaller, nextDisplay, previousDisplay, restore

    var title: String {
        switch self {
        case .leftHalf: L("Левая половина")
        case .rightHalf: L("Правая половина")
        case .topHalf: L("Верхняя половина")
        case .bottomHalf: L("Нижняя половина")
        case .centerHalf: L("Половина по центру")
        case .topLeft: L("Левая верхняя четверть")
        case .topRight: L("Правая верхняя четверть")
        case .bottomLeft: L("Левая нижняя четверть")
        case .bottomRight: L("Правая нижняя четверть")
        case .firstThird: L("Левая треть")
        case .centerThird: L("Треть по центру")
        case .lastThird: L("Правая треть")
        case .firstTwoThirds: L("Две трети слева")
        case .centerTwoThirds: L("Две трети по центру")
        case .lastTwoThirds: L("Две трети справа")
        case .maximize: L("Развернуть окно")
        case .center: L("Окно по центру")
        case .reasonableSize: L("Удобный размер окна")
        case .larger: L("Окно больше")
        case .smaller: L("Окно меньше")
        case .nextDisplay: L("Окно на следующий дисплей")
        case .previousDisplay: L("Окно на предыдущий дисплей")
        case .restore: L("Вернуть окно как было")
        }
    }

    var english: String {
        switch self {
        case .leftHalf: "left half"
        case .rightHalf: "right half"
        case .topHalf: "top half"
        case .bottomHalf: "bottom half"
        case .centerHalf: "center half"
        case .topLeft: "top left"
        case .topRight: "top right"
        case .bottomLeft: "bottom left"
        case .bottomRight: "bottom right"
        case .firstThird: "first third"
        case .centerThird: "center third"
        case .lastThird: "last third"
        case .firstTwoThirds: "first two thirds"
        case .centerTwoThirds: "center two thirds"
        case .lastTwoThirds: "last two thirds"
        case .maximize: "maximize window"
        case .center: "center window"
        case .reasonableSize: "reasonable size"
        case .larger: "make larger"
        case .smaller: "make smaller"
        case .nextDisplay: "next display"
        case .previousDisplay: "previous display"
        case .restore: "restore window"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .centerHalf, .centerThird, .centerTwoThirds, .center: "rectangle.center.inset.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .firstThird, .firstTwoThirds: "rectangle.leadingthird.inset.filled"
        case .lastThird, .lastTwoThirds: "rectangle.trailingthird.inset.filled"
        case .maximize: "rectangle.inset.filled"
        case .reasonableSize: "macwindow"
        case .larger: "arrow.up.left.and.arrow.down.right"
        case .smaller: "arrow.down.right.and.arrow.up.left"
        case .nextDisplay, .previousDisplay: "display.2"
        case .restore: "arrow.uturn.backward"
        }
    }

    /// Rectangle's public defaults: ⌃⌥ + arrows, U I J K, D F G, E T, ↵, C, − =, ⌫; ⌃⌥⌘ + ←/→ for displays.
    var rectangleShortcut: Shortcut? {
        let co = HotKey.control | HotKey.option
        let key: Int? = switch self {
        case .leftHalf: kVK_LeftArrow
        case .rightHalf: kVK_RightArrow
        case .topHalf: kVK_UpArrow
        case .bottomHalf: kVK_DownArrow
        case .topLeft: kVK_ANSI_U
        case .topRight: kVK_ANSI_I
        case .bottomLeft: kVK_ANSI_J
        case .bottomRight: kVK_ANSI_K
        case .firstThird: kVK_ANSI_D
        case .centerThird: kVK_ANSI_F
        case .lastThird: kVK_ANSI_G
        case .firstTwoThirds: kVK_ANSI_E
        case .lastTwoThirds: kVK_ANSI_T
        case .maximize: kVK_Return
        case .center: kVK_ANSI_C
        case .smaller: kVK_ANSI_Minus
        case .larger: kVK_ANSI_Equal
        case .restore: kVK_Delete
        case .nextDisplay: kVK_RightArrow
        case .previousDisplay: kVK_LeftArrow
        default: nil
        }
        guard let key else { return nil }
        let display = self == .nextDisplay || self == .previousDisplay
        return Shortcut(keyCode: UInt32(key), modifiers: display ? co | HotKey.command : co)
    }
}

final class WindowManager {
    static let shared = WindowManager()

    /// Per window: the frame before the first command of a chain (for Restore) and the last frame Nook set.
    private struct Memory {
        var restore: CGRect
        var applied: CGRect
    }

    private let queue = DispatchQueue(label: "nook.windows", qos: .userInitiated)
    private var memory: [String: Memory] = [:]

    /// Screens in Accessibility coordinates (top-left origin of the primary display), read on the main thread.
    private struct Screen {
        let frame: CGRect
        let box: CGRect
    }

    func perform(_ action: WindowAction) {
        guard AXIsProcessTrusted() else {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        func flip(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height)
        }
        // The visible frame leaves out the menu bar, the Dock and the camera housing.
        let screens = NSScreen.screens.map { Screen(frame: flip($0.frame), box: flip($0.visibleFrame)) }
        let pid = app.processIdentifier
        queue.async { [weak self] in self?.apply(action, pid: pid, screens: screens) }
    }

    private func apply(_ action: WindowAction, pid: pid_t, screens: [Screen]) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        let window = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 1)
        // Minimized or full-screen windows are left alone.
        if bool(window, kAXMinimizedAttribute) || bool(window, "AXFullScreen") { return }
        guard let frame = frame(of: window), !screens.isEmpty else { return }
        let key = "\(pid)-\(CFHash(window))"
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let index = screens.firstIndex { $0.frame.contains(center) } ?? 0
        let box = screens[index].box

        if action == .restore {
            guard let saved = memory[key] else { return }
            set(window, saved.restore)
            memory[key] = nil
            return
        }
        // Moved or resized by hand since the last command: a new chain, a new restore point.
        var entry = memory[key]
        if let current = entry, current.applied.distance(to: frame) > 2 { entry = nil }
        let restore = entry?.restore ?? frame

        var target: CGRect
        switch action {
        case .leftHalf: target = part(box, x: 0, y: 0, w: 0.5, h: 1)
        case .rightHalf: target = part(box, x: 0.5, y: 0, w: 0.5, h: 1)
        case .topHalf: target = part(box, x: 0, y: 0, w: 1, h: 0.5)
        case .bottomHalf: target = part(box, x: 0, y: 0.5, w: 1, h: 0.5)
        case .centerHalf: target = part(box, x: 0.25, y: 0, w: 0.5, h: 1)
        case .topLeft: target = part(box, x: 0, y: 0, w: 0.5, h: 0.5)
        case .topRight: target = part(box, x: 0.5, y: 0, w: 0.5, h: 0.5)
        case .bottomLeft: target = part(box, x: 0, y: 0.5, w: 0.5, h: 0.5)
        case .bottomRight: target = part(box, x: 0.5, y: 0.5, w: 0.5, h: 0.5)
        case .firstThird: target = part(box, x: 0, y: 0, w: 1.0 / 3, h: 1)
        case .centerThird: target = part(box, x: 1.0 / 3, y: 0, w: 1.0 / 3, h: 1)
        case .lastThird: target = part(box, x: 2.0 / 3, y: 0, w: 1.0 / 3, h: 1)
        case .firstTwoThirds: target = part(box, x: 0, y: 0, w: 2.0 / 3, h: 1)
        case .centerTwoThirds: target = part(box, x: 1.0 / 6, y: 0, w: 2.0 / 3, h: 1)
        case .lastTwoThirds: target = part(box, x: 1.0 / 3, y: 0, w: 2.0 / 3, h: 1)
        case .maximize: target = box
        case .center:
            target = CGRect(x: box.midX - frame.width / 2, y: box.midY - frame.height / 2, width: frame.width, height: frame.height)
        case .reasonableSize:
            let size = CGSize(width: min(box.width * 0.6, 1025), height: min(box.height * 0.6, 900))
            target = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
        case .larger, .smaller:
            // 5 % of the screen per step, around the centre; never below 200 × 150 or 15 % of the screen.
            let sign: CGFloat = action == .larger ? 1 : -1
            let dx = (box.width * 0.05).rounded() * sign, dy = (box.height * 0.05).rounded() * sign
            let minimum = CGSize(width: max(200, box.width * 0.15), height: max(150, box.height * 0.15))
            let width = min(box.width, max(minimum.width, frame.width + dx))
            let height = min(box.height, max(minimum.height, frame.height + dy))
            target = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1 else { return }
            let step = action == .nextDisplay ? 1 : screens.count - 1
            let other = screens[(index + step) % screens.count].box
            // Same place and share of the screen, on the other display.
            target = CGRect(x: other.minX + (frame.minX - box.minX) / box.width * other.width,
                            y: other.minY + (frame.minY - box.minY) / box.height * other.height,
                            width: min(other.width, frame.width / box.width * other.width),
                            height: min(other.height, frame.height / box.height * other.height))
        case .restore:
            return
        }
        target = clamp(round(target), into: action == .nextDisplay || action == .previousDisplay ? target : box)
        set(window, target)
        memory[key] = Memory(restore: restore, applied: self.frame(of: window) ?? target)
        if memory.count > 64 { memory.removeValue(forKey: memory.keys.first!) }
    }

    private func part(_ box: CGRect, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
        CGRect(x: box.minX + box.width * x, y: box.minY + box.height * y, width: box.width * w, height: box.height * h)
    }

    /// Edges rounded one by one, so two halves share the same line.
    private func round(_ rect: CGRect) -> CGRect {
        let minX = rect.minX.rounded(), minY = rect.minY.rounded()
        return CGRect(x: minX, y: minY, width: rect.maxX.rounded() - minX, height: rect.maxY.rounded() - minY)
    }

    private func clamp(_ rect: CGRect, into box: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, box.width)
        result.size.height = min(result.height, box.height)
        result.origin.x = min(max(result.minX, box.minX), box.maxX - result.width)
        result.origin.y = min(max(result.minY, box.minY), box.maxY - result.height)
        return result
    }

    // MARK: Accessibility

    private func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// Size, position, size again: some apps clamp the size to the old screen until the window has moved.
    private func set(_ window: AXUIElement, _ rect: CGRect) {
        var size = rect.size
        var origin = rect.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else { return }
        var settable: DarwinBoolean = false
        let canMove = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
        guard canMove else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }

    private func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

private extension CGRect {
    /// The largest edge difference.
    func distance(to other: CGRect) -> CGFloat {
        max(abs(minX - other.minX), abs(minY - other.minY), abs(maxX - other.maxX), abs(maxY - other.maxY))
    }
}
