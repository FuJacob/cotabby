import Foundation

/// What `VisualContextCoordinator.startSessionIfNeeded` should do for an incoming focus.
nonisolated enum VisualContextStartDecision: Equatable {
    /// Same field is already capturing or already waiting out its settle window — do nothing.
    case ignore
    /// New or changed field, or the same field whose session was blocked on Screen Recording
    /// permission that is now granted — tear down whatever is active and (re)arm the debounced
    /// capture.
    case start
}

/// Pure coalescing decision for the visual-context capture pipeline.
///
/// Chromium/Electron apps flap the focused AX element, calling `startSessionIfNeeded` repeatedly with
/// a churning `focusChangeSequence`. This collapses those repeats: a call matching the active or the
/// pending field is ignored, so the screenshot -> OCR -> cleanup pipeline runs once focus is stable
/// instead of once per flap (the #280 retrigger storm). Kept pure so the invariants are unit-testable.
enum VisualContextStartCoalescer {
    static func decide(
        incoming: FocusedInputIdentity,
        active: FocusedInputIdentity?,
        activeIsBlockedOnScreenRecording: Bool,
        hasScreenRecordingPermission: Bool,
        pending: FocusedInputIdentity?
    ) -> VisualContextStartDecision {
        if active == incoming {
            return activeIsBlockedOnScreenRecording && hasScreenRecordingPermission ? .start : .ignore
        }

        if pending == incoming {
            return .ignore
        }

        return .start
    }
}
