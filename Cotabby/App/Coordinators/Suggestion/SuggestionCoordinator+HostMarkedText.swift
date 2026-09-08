import Foundation

/// File overview:
/// The hold the coordinator enters while the host shows uncommitted text of its own: macOS inline
/// predictive text after the caret, or an IME composition before it (see `HostMarkedTextPolicy`).
///
/// While the hold is on, Cotabby generates nothing and paints nothing, because the host's gray
/// prediction already occupies the spot a ghost would take and a composition is text the user has
/// not finished. The live session is kept, not invalidated: the moment the host commits or drops
/// its span, the next focus snapshot reconciles the same session against the real text and the
/// ghost returns (or advances, when the user typed through it meanwhile) without a regeneration.
extension SuggestionCoordinator {
    static let hostMarkedTextHoldReason =
        "Overlay hidden while the app shows its own inline prediction or composes text."

    /// Enters or leaves the hold according to `snapshot`. Returns true when the snapshot carries
    /// marked text, in which case the caller must not reconcile, generate, or present from it.
    func updateHostMarkedTextHold(for snapshot: FocusSnapshot) -> Bool {
        guard snapshot.context?.hasHostMarkedText == true else {
            if isHoldingForHostMarkedText {
                isHoldingForHostMarkedText = false
                logStage(
                    "host-marked-text-released",
                    workID: currentWorkID,
                    generation: latestGenerationNumber,
                    message: "The app committed or dropped its own inline text; resuming."
                )
            }
            return false
        }
        holdForHostMarkedText()
        return true
    }

    /// Pauses generation and hides the ghost without touching the active session.
    func holdForHostMarkedText() {
        cancelPredictionWork()
        let wasHolding = isHoldingForHostMarkedText
        isHoldingForHostMarkedText = true
        if overlayState.isVisible {
            hideOverlay(reason: Self.hostMarkedTextHoldReason)
        }
        if interactionState.activeSession == nil {
            switch state {
            case .disabled, .idle:
                break
            default:
                state = .idle
            }
        }
        if !wasHolding {
            logStage(
                "host-marked-text-hold",
                workID: currentWorkID,
                generation: latestGenerationNumber,
                message: "Holding while the app shows its own inline prediction or composes text."
            )
        }
    }
}
