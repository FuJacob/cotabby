import Foundation

/// File overview:
/// Lifecycle entry points and user preference changes for `SuggestionCoordinator`.
/// These methods are the closest thing this subsystem has to "public commands" from the app and UI.
extension SuggestionCoordinator {
    // MARK: - Lifecycle

    /// Reconciles coordinator state with the current permission and focus environment.
    func start() {
        reconcileWithCurrentEnvironment()
    }

    /// Cancels any pending work and detaches long-lived callbacks during shutdown.
    func stop() {
        cancelPredictionWork()
        visualContextCoordinator.cancel(resetState: true)
        hideOverlay(reason: "Overlay hidden because Tabby stopped observing suggestions.")
        inputMonitor.onEvent = nil
        inputMonitor.onSuppressedSyntheticInput = nil
        overlayController.onStateChange = nil
        visualContextCoordinator.onStateChange = nil
        visualContextCoordinator.onInjectedContextReady = nil
    }

    /// Clears any active suggestion work before the runtime swaps to a different model.
    /// This prevents stale completions from the previous model from surviving the switch.
    func prepareForRuntimeModelSwitch() {
        cancelPredictionWork()
        interactionState.resetAll()
        visualContextCoordinator.cancel(resetState: true)
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because the runtime model is switching.")
        state = .idle
        latestStageMessage = "Idle: runtime model switching reset active suggestion state."
    }

    // MARK: - Settings

    /// The coordinator reacts to settings changes instead of owning those preferences directly.
    /// That separation keeps "user configuration" distinct from "active autocomplete session."
    func handleSuggestionSettingsChange(_ snapshot: SuggestionSettingsSnapshot) {
        guard settingsSnapshot != snapshot else {
            return
        }

        let previousSnapshot = settingsSnapshot
        settingsSnapshot = snapshot
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: "Overlay hidden because autocomplete settings changed.")
        state = .idle

        if previousSnapshot.selectedEngine != snapshot.selectedEngine {
            latestStageMessage = "Updated autocomplete engine to \(snapshot.selectedEngine.displayLabel)."
        } else if previousSnapshot.selectedWordCountPreset != snapshot.selectedWordCountPreset {
            latestStageMessage = "Updated suggestion length to \(snapshot.selectedWordCountPreset.displayLabel)."
        } else if previousSnapshot.effectivePromptMode != snapshot.effectivePromptMode {
            latestStageMessage = "Updated prompt mode to \(snapshot.effectivePromptMode.displayLabel)."
        } else {
            latestStageMessage = "Updated autocomplete settings."
        }

        // Legacy screenshot/OCR context capture is disabled for both prompt modes while we rebuild.
        if visualContextStatus != .idle {
            visualContextCoordinator.cancel(resetState: true)
        }

        if SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusModel.snapshot
        )
        {
            schedulePrediction()
        }
    }
}
