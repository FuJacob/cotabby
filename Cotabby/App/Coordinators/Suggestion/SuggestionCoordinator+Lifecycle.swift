import Foundation
import Logging

/// File overview:
/// Lifecycle entry points and user preference changes for `SuggestionCoordinator`.
/// These methods are the closest thing this subsystem has to "public commands" from the app and UI.
extension SuggestionCoordinator {
    // MARK: - Lifecycle

    /// Reconciles coordinator state with the current permission and focus environment.
    func start() {
        CotabbyLogger.suggestion.info("Suggestion coordinator starting")
        reconcileWithCurrentEnvironment()
    }

    /// Cancels any pending work and detaches long-lived callbacks during shutdown.
    func stop() {
        CotabbyLogger.suggestion.info("Suggestion coordinator stopping")
        suggestionPresentationTiming.clear()
        // A deferred screen-context retirement would otherwise wake after stop and schedule work.
        settleDeferredScreenContextChange()
        cancelPredictionWork()
        resetCachedGenerationContext()
        visualContextCoordinator.cancel(resetState: true)
        hideOverlay(reason: "Overlay hidden because Cotabby stopped observing suggestions.")
        inputMonitor.onEvent = nil
        inputMonitor.onSuppressedSyntheticInput = nil
        overlayController.onStateChange = nil
        visualContextCoordinator.onStateChange = nil
        visualContextCoordinator.onInjectedContextReady = nil
        visualContextCoordinator.refreshContextProvider = nil
    }

    /// Clears any active suggestion work before the runtime swaps to a different model.
    /// This prevents stale completions from the previous model from surviving the switch.
    func prepareForRuntimeModelSwitch() {
        CotabbyLogger.suggestion.info("Preparing for runtime model switch, clearing active state")
        suggestionPresentationTiming.clear()
        // The visual-context reset below makes a deferred screen-context change moot; left pending,
        // it would wake after the switch and retire whatever the new model shows.
        settleDeferredScreenContextChange()
        cancelPredictionWork()
        resetCachedGenerationContext()
        interactionState.resetAll()
        visualContextCoordinator.cancel(resetState: true)
        retireSuggestion(reason: "Overlay hidden because the runtime model is switching.", clearDiagnostics: true)
    }

    // MARK: - Settings

    /// The coordinator reacts to settings changes instead of owning those preferences directly.
    /// That separation keeps "user configuration" distinct from "active autocomplete session."
    func handleSuggestionSettingsChange(_ snapshot: SuggestionSettingsSnapshot) {
        guard settingsSnapshot != snapshot else {
            return
        }

        CotabbyLogger.suggestion.info("Settings changed, resetting suggestion state")
        settingsSnapshot = snapshot
        // Same as a model switch: the reset below restarts visual context and schedules its own
        // prediction, which a deferred screen-context change would otherwise retire on waking.
        settleDeferredScreenContextChange()
        cancelPredictionWork()
        resetCachedGenerationContext()
        retireSuggestion(reason: "Overlay hidden because autocomplete settings changed.", clearDiagnostics: true)

        // Cancel any obsolete context, then restart only when the subsystem is not disabled.
        visualContextCoordinator.cancel(resetState: true)
        if let focusedSnapshot = focusModel.snapshot.context {
            startVisualContextIfAllowed(for: focusedSnapshot, focusSnapshot: focusModel.snapshot)
        }

        if currentDisabledReason(focusSnapshot: focusModel.snapshot) == nil {
            schedulePrediction()
        }
    }

    /// Called by the visual service's slow refresh timer. Orchestration owns permission/settings
    /// policy; the service owns the timer and pixels. A fresh AX read prevents a background capture
    /// from using the field that was focused three seconds ago after the user changes windows.
    func currentVisualRefreshContext() -> FocusedInputSnapshot? {
        // A window can switch immediately after a poll; capture authorization cannot reuse its age window.
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot
        guard let context = snapshot.context, !context.isSecure,
              shouldCaptureVisualContext(for: snapshot) else { return nil }
        return context
    }
}
