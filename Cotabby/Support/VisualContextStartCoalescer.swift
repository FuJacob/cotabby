import Foundation

/// A focused field's identity for visual-context coalescing: the AX element plus the monotonic
/// focus-change counter the tracker assigns. `elementIdentifier` alone is unreliable (macOS recycles
/// `CFHash` values across unrelated elements), so both are compared together.
nonisolated struct VisualContextFieldIdentity: Equatable {
    let elementIdentifier: String
    let focusChangeSequence: UInt64
}

/// What `VisualContextCoordinator.startSessionIfNeeded` should do for an incoming focus.
nonisolated enum VisualContextStartDecision: Equatable {
    /// Same field is already capturing or already waiting out its settle window — do nothing.
    case ignore
    /// The active session for this field was blocked on Screen Recording permission that is now
    /// granted — tear it down and start fresh.
    case recoverPermissionThenStart
    /// New or changed field — (re)arm the debounced capture.
    case start
}

/// Pure coalescing decision for the visual-context capture pipeline.
///
/// Chromium/Electron apps flap the focused AX element, calling `startSessionIfNeeded` repeatedly with
/// a churning `focusChangeSequence`. This collapses those repeats: a call matching the active or the
/// pending field is ignored, so the screenshot -> OCR -> summarize pipeline runs once focus is stable
/// instead of once per flap (the #280 retrigger storm). Kept pure so the invariants are unit-testable.
enum VisualContextStartCoalescer {
    static func decide(
        incoming: VisualContextFieldIdentity,
        active: VisualContextFieldIdentity?,
        activeIsBlockedOnScreenRecording: Bool,
        hasScreenRecordingPermission: Bool,
        pending: VisualContextFieldIdentity?
    ) -> VisualContextStartDecision {
        if active == incoming {
            if activeIsBlockedOnScreenRecording, hasScreenRecordingPermission {
                return .recoverPermissionThenStart
            }
            return .ignore
        }

        if pending == incoming {
            return .ignore
        }

        return .start
    }
}
