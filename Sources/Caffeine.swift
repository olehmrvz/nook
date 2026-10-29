import Foundation
import IOKit.pwr_mgt

/// "Coffee": keeps the Mac from going to sleep while idle (agents left running overnight).
/// The display still turns off as usual; closing the lid still sleeps the Mac.
final class Caffeine: ObservableObject {
    @Published private(set) var on = false
    private var assertion: IOPMAssertionID = 0

    func toggle() { set(!on) }

    func set(_ value: Bool) {
        guard value != on else { return }
        if value {
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Nook: coffee mode" as CFString, &assertion)
            guard ok == kIOReturnSuccess else { return }
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        on = value
    }

    deinit { if on { IOPMAssertionRelease(assertion) } }
}
