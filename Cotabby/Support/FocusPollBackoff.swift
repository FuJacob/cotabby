import Foundation

/// Pure idle-backoff bookkeeping for the focus poll timer.
///
/// Extracted from `FocusTracker.handleTimerTick` so the state transitions — how `idleCaptureCount`
/// grows when captures stop changing and snaps back to full cadence on activity — are unit-testable
/// without driving real Accessibility captures or a live timer. The fix for #280: an idle machine
/// shouldn't run the expensive AX tree walk ~12.5x/second when nothing is changing.
struct FocusPollBackoff {
    /// Consecutive captures that produced no change. Drives the stride.
    private(set) var idleCaptureCount = 0
    /// Base timer ticks elapsed since the last expensive capture.
    private var ticksSinceCapture = 0

    /// Cap on `idleCaptureCount` so a long idle period can't overflow; the stride is already maxed
    /// well before this is reached.
    static let idleCaptureCountCap = 60

    /// How many base poll ticks to wait between expensive captures, given how many consecutive
    /// captures have produced no change.
    ///
    /// The first few idle captures stay at full cadence so a brief pause doesn't make the field feel
    /// laggy; sustained idleness ramps toward ~800ms (at the 80ms base) before the next AX walk.
    static func captureStride(idleCaptureCount: Int) -> Int {
        switch idleCaptureCount {
        case ..<5:
            return 1
        case ..<12:
            return 3
        case ..<30:
            return 6
        default:
            return 10
        }
    }

    /// Advances one timer tick. Returns `true` when the caller should run the expensive capture now.
    mutating func shouldCaptureOnTick() -> Bool {
        ticksSinceCapture += 1
        guard ticksSinceCapture >= Self.captureStride(idleCaptureCount: idleCaptureCount) else {
            return false
        }
        ticksSinceCapture = 0
        return true
    }

    /// Records a completed capture: a change returns the loop to full cadence, no change grows the stride.
    mutating func recordCapture(didChange: Bool) {
        idleCaptureCount = didChange ? 0 : min(idleCaptureCount + 1, Self.idleCaptureCountCap)
    }

    /// An explicit refresh (real activity, e.g. a keystroke) returns the loop to full cadence.
    mutating func reset() {
        idleCaptureCount = 0
        ticksSinceCapture = 0
    }
}
