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

    /// Cap on `idleCaptureCount` so a long idle period can't overflow; the stride is already maxed
    /// well before this is reached.
    static let idleCaptureCountCap = 60

    /// Poll-interval multiplier for the given idle level. The focus timer runs at
    /// `baseInterval * captureStride`, so this is how much an idle machine stretches the gap between
    /// expensive Accessibility walks.
    ///
    /// The first few idle captures stay at full cadence (stride 1) so a brief pause doesn't make the
    /// field feel laggy; sustained idleness ramps toward 10x (e.g. ~500ms at the 50ms base) before
    /// the next AX walk.
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

    /// The current poll-interval multiplier. `FocusTracker` multiplies its base interval by this to
    /// get the interval the timer actually runs at, so an idle machine wakes the main thread every
    /// `base * stride` instead of waking every base tick only to skip the work.
    var captureStride: Int {
        Self.captureStride(idleCaptureCount: idleCaptureCount)
    }

    /// Records a completed capture: a change returns the loop to full cadence, no change grows the
    /// stride.
    mutating func recordCapture(didChange: Bool) {
        idleCaptureCount = didChange ? 0 : min(idleCaptureCount + 1, Self.idleCaptureCountCap)
    }

    /// An explicit refresh (real activity, e.g. a keystroke) returns the loop to full cadence.
    mutating func reset() {
        idleCaptureCount = 0
    }
}
