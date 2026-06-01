import Foundation

/// File overview:
/// Suppresses transient `Supported → Blocked → Supported` capability flicker on the *same* focused
/// element so the suggestion overlay does not tear down and rebuild every time a host app momentarily
/// republishes its focused field.
///
/// Background. `FocusCapabilityResolver` re-derives capability from live AX attributes on every poll
/// with no temporal smoothing. Some Catalyst-style fields (Apple Calendar's event editor is the
/// reproduction) briefly drop one of `textValue` / `selectionRange` / `caretBounds` while they
/// redraw, which collapses capability to Blocked for a single poll and bounces back to Supported on
/// the next. Without this gate every flicker drives `handleFocusSnapshotChange` to call
/// `disablePredictionsPreservingVisualContext` → `OverlayController.hide` → `panel.orderOut(nil)`,
/// which the user sees as the overlay opening and closing several times per second.
///
/// The gate is intentionally tiny and pure: it tracks the most recently delivered Supported element
/// identity and a consecutive-Blocked counter, and tells the caller whether to apply the new
/// snapshot or keep treating the field as Supported for now. A persistent loss of capability (the
/// real "field went away" case) clears the gate after `requiredConsecutiveBlockedReads` so the
/// downgrade still propagates promptly — at the observed ~80–150 ms poll cadence that is roughly
/// 160–300 ms of suppression, well above the ~13 ms flicker pairs seen in the logs but short enough
/// that genuine focus loss is not perceptible.
struct FocusCapabilityFlickerGate {
    /// How many consecutive Blocked snapshots on the same element must be observed before the gate
    /// releases the downgrade. Two is enough to swallow the single-poll flicker without delaying
    /// real focus-loss perceptibly at typical poll cadence.
    static let requiredConsecutiveBlockedReads = 2

    /// Outcome the caller acts on.
    enum Decision: Equatable {
        /// Apply this snapshot as-is.
        case apply
        /// Treat as a transient flicker: pretend the previous Supported snapshot is still current.
        /// `pendingBlockedReadCount` is exposed for diagnostic logging only.
        case suppress(pendingBlockedReadCount: Int)
    }

    private var lastDeliveredSupportedElementID: String?
    private var consecutiveBlockedReadCount: Int = 0

    /// Feed every snapshot through here before letting it drive coordinator state.
    mutating func evaluate(_ snapshot: FocusSnapshot) -> Decision {
        switch snapshot.capability {
        case .supported:
            lastDeliveredSupportedElementID = snapshot.context?.elementIdentifier
            consecutiveBlockedReadCount = 0
            return .apply

        case .blocked:
            // Only debounce when we are still observing the same element that was just Supported.
            // A different (or missing) element identifier is a genuine focus change and must
            // propagate immediately.
            guard let lastID = lastDeliveredSupportedElementID,
                  let currentID = snapshot.context?.elementIdentifier,
                  currentID == lastID
            else {
                lastDeliveredSupportedElementID = nil
                consecutiveBlockedReadCount = 0
                return .apply
            }

            consecutiveBlockedReadCount += 1
            if consecutiveBlockedReadCount >= Self.requiredConsecutiveBlockedReads {
                lastDeliveredSupportedElementID = nil
                consecutiveBlockedReadCount = 0
                return .apply
            }
            return .suppress(pendingBlockedReadCount: consecutiveBlockedReadCount)

        case .unsupported:
            // Unsupported is "no focused text input at all" — never debounce; the user has left the
            // field and the overlay must hide immediately.
            lastDeliveredSupportedElementID = nil
            consecutiveBlockedReadCount = 0
            return .apply
        }
    }
}
