import Foundation

/// Where the suggestion pipeline is in its cycle, as the coordinator's own gates read it.
///
/// Production reads two facts from it: whether predictions are disabled and for which reason (a
/// field that stays blocked sends every keystroke to the disable path, which must not tear down
/// again for the same reason), and whether any cycle is pending or showing at all. The cycle's
/// real state lives with its owners: the debounce and generation tasks in
/// `SuggestionWorkController`, the suggestion in `SuggestionInteractionState`, the ghost in
/// `OverlayState`. The phase therefore carries no copy of the suggestion text or of a failure
/// message: nothing read them, and every advance of the session would have had to re-sync them.
enum SuggestionPipelinePhase: Equatable {
    case idle
    case disabled(String)
    case debouncing
    case generating
    case ready
    case failed

    /// Idle or disabled: nothing is scheduled, in flight, or on screen that a teardown would still
    /// have to clear. Entering `disabled` already ran the full teardown.
    var isSettled: Bool {
        switch self {
        case .idle, .disabled:
            return true
        case .debouncing, .generating, .ready, .failed:
            return false
        }
    }

    /// Leaves `disabled` once availability allows predictions again. Any other phase describes work
    /// the availability change did not touch, so it is kept.
    mutating func reenable() {
        if case .disabled = self {
            self = .idle
        }
    }

    /// Returns to idle after the cycle's work or suggestion was dropped. A disabled pipeline stays
    /// disabled: only an availability change may end that.
    mutating func settle() {
        if case .disabled = self {
            return
        }
        self = .idle
    }
}
