import Foundation

/// File overview:
/// Focus, permission, and keyboard-event entry points for `SuggestionCoordinator`.
/// This file answers: "what should happen when the environment changes or the user types?"
extension SuggestionCoordinator {
    // MARK: - Environment and Input Handling

    func handlePermissionChange() {
        reconcileWithCurrentEnvironment()

        if SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            handleSupportedSnapshot(focusModel.snapshot)
        }
    }

    func handleFocusSnapshotChange(_ snapshot: FocusSnapshot) {
        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: snapshot
        ) {
            disablePredictions(reason: disabledReason)
        } else {
            handleSupportedSnapshot(snapshot)
        }
    }

    func handleSupportedSnapshot(_ snapshot: FocusSnapshot) {
        guard let focusedContext = snapshot.context else {
            disablePredictions(reason: "No focused text input.")
            return
        }

        // Legacy screenshot/OCR context capture is disabled for both prompt modes while we rebuild.
        if visualContextStatus != .idle {
            visualContextCoordinator.cancel(resetState: true)
        }

        if case .disabled = state {
            state = .idle
        }

        if interactionState.activeSession != nil {
            reconcileActiveSession(with: snapshot)
            return
        }

        if interactionState.hasFocusedElementChanged(comparedTo: focusedContext) {
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because the focused field changed.")
            state = .idle
        }

        if overlayState.isVisible {
            hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
        }
    }

    func handleInputEvent(_ event: CapturedInputEvent) -> Bool {
        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            disablePredictions(reason: disabledReason)
            return false
        }

        if event.kind == .tab {
            return acceptCurrentSuggestion()
        }

        if let activeSession = interactionState.activeSession {
            return handleInputEvent(event, with: activeSession)
        }

        if event.shouldClearSuggestion {
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: SuggestionSessionReconciler.overlayHideReason(for: event))
            if !event.shouldSchedulePrediction {
                state = .idle
            }
        }

        if event.shouldSchedulePrediction {
            schedulePrediction()
        }

        return false
    }

    func handleSuppressedSyntheticInput() {
        logStage(
            "suppressed-synthetic-input",
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: "Ignored Tabby's own synthetic key event."
        )
    }

    /// While a suggestion tail is active, normal typing is interpreted relative to that tail first.
    /// This is the same idea as reconciling optimistic UI with the eventual live editor state:
    /// keep the existing session only when the user's new input is still consistent with it.
    func handleInputEvent(_ event: CapturedInputEvent, with session: ActiveSuggestionSession) -> Bool {
        switch event.kind {
        case .textMutation:
            if advanceActiveSessionIfTypedCharactersMatch(event.characters, session: session) {
                return false
            }

            invalidateActiveSuggestion(
                reason: SuggestionSessionReconciler.overlayHideReason(for: event),
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                schedulePrediction()
            }
            return false

        case .shortcutMutation:
            invalidateActiveSuggestion(
                reason: "Overlay hidden because a shortcut changed the text and invalidated the current suggestion.",
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                schedulePrediction()
            }
            return false

        case .navigation, .dismissal:
            invalidateActiveSuggestion(
                reason: SuggestionSessionReconciler.overlayHideReason(for: event),
                clearDiagnostics: false
            )
            state = .idle
            return false

        case .other, .tab:
            return false
        }
    }
}
