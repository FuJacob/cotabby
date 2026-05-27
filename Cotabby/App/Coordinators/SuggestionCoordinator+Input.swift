import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Focus, permission, and keyboard-event entry points for `SuggestionCoordinator`.
/// This file answers: "what should happen when the environment changes or the user types?"
extension SuggestionCoordinator {
    // MARK: - Environment and Input Handling

    func handlePermissionChange() {
        CotabbyLogger.suggestion.debug("Permission state changed, reconciling")
        reconcileWithCurrentEnvironment()

        if SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            handleSupportedSnapshot(focusModel.snapshot)
        }
    }

    func handleFocusSnapshotChange(_ snapshot: FocusSnapshot) {
        CotabbyLogger.suggestion.trace(
            "Focus snapshot changed: app=\(snapshot.applicationName) capability=\(snapshot.capability.shortLabel) \(focusDiagnostics(for: snapshot))"
        )
        // Start capturing visual context for a newly focused input even when predictions are
        // temporarily disabled by transient field states (e.g., "text is selected" or "secure
        // field"). Skip capture entirely when the subsystem is hard-disabled (globally off,
        // per-app disabled, terminal apps, or missing permissions) to avoid wasted compute.
        if let context = snapshot.context,
           SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
               globallyEnabled: settingsSnapshot.isGloballyEnabled,
               disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
               inputMonitoringGranted: permissionManager.inputMonitoringGranted,
               screenRecordingGranted: permissionManager.screenRecordingGranted,
               focusSnapshot: snapshot,
               isFastModeEnabled: settingsSnapshot.isFastModeEnabled
           ) {
            visualContextCoordinator.startSessionIfNeeded(for: context)
        }

        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: snapshot
        ) {
            disablePredictionsPreservingVisualContext(reason: disabledReason)
        } else {
            handleSupportedSnapshot(snapshot)
        }
    }

    func handleSupportedSnapshot(_ snapshot: FocusSnapshot) {
        guard let focusedContext = snapshot.context else {
            disablePredictions(reason: "No focused text input.")
            return
        }

        // Start capturing visual context for newly focused input. Gated like the focus-change path
        // (and skipped in fast mode) so this entry point never kicks off screenshot/OCR work that the
        // earlier `shouldCaptureVisualContext` check already declined.
        if SuggestionAvailabilityEvaluator.shouldCaptureVisualContext(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: snapshot,
            isFastModeEnabled: settingsSnapshot.isFastModeEnabled
        ) {
            visualContextCoordinator.startSessionIfNeeded(for: focusedContext)
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
            resetCachedGenerationContext()
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
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            disablePredictions(reason: disabledReason)
            return false
        }

        if event.kind == .acceptance {
            return acceptCurrentSuggestion()
        }

        if event.kind == .fullAcceptance {
            return acceptEntireSuggestion()
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
            // Refresh the AX snapshot off the synchronous tap path (see
            // `scheduleNonBlockingFocusRefresh`) so the resolve cost never delays this keystroke.
            // The fresh snapshot lands before the post-debounce generation re-reads it.
            scheduleNonBlockingFocusRefresh()
            schedulePrediction()
        }

        return false
    }

    func handleSuppressedSyntheticInput() {
        logStage(
            "suppressed-synthetic-input",
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: "Ignored Cotabby's own synthetic key event."
        )
    }

    /// Refreshes the focus snapshot without blocking keystroke delivery.
    ///
    /// `InputMonitor` runs the event-tap callback (and therefore `handleInputEvent`) synchronously
    /// *before* macOS hands the keystroke to the focused app, so a synchronous `refreshNow()` here
    /// adds the full Accessibility-resolve latency to every character typed. That resolve grows with
    /// the field's text and AX subtree (candidate discovery, deep-geometry walks, full-value reads),
    /// which is why typing into large or Chromium-based fields lagged badly while editing existing
    /// text. Deferring the refresh to the next main-actor turn keeps the keystroke instant; the
    /// snapshot still refreshes promptly, before the user's next event (e.g. a Tab acceptance) and
    /// well before the post-debounce `generateFromCurrentFocus`, which re-reads it anyway.
    ///
    /// Coalesced via `isFocusRefreshScheduled`: continuous typing collapses to at most one pending
    /// refresh, which reads the latest live AX state when it runs and so already reflects every
    /// keystroke queued before it. The 80ms poll remains the backstop for freshness.
    func scheduleNonBlockingFocusRefresh() {
        guard !isFocusRefreshScheduled else {
            return
        }
        isFocusRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.isFocusRefreshScheduled = false
            self.focusModel.refreshNow()
        }
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
                scheduleNonBlockingFocusRefresh()
                schedulePrediction()
            }
            return false

        case .shortcutMutation:
            invalidateActiveSuggestion(
                reason: "Overlay hidden because a shortcut changed the text and invalidated the current suggestion.",
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                scheduleNonBlockingFocusRefresh()
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

        case .other, .acceptance, .fullAcceptance:
            return false
        }
    }
}

private extension SuggestionCoordinator {
    /// Website editors often expose unstable AX trees, so this log keeps the next repro actionable
    /// without writing the user's message text into the debug file.
    func focusDiagnostics(for snapshot: FocusSnapshot) -> String {
        let inspection = snapshot.inspection
        guard let context = snapshot.context else {
            return "reason=\"\(snapshot.capability.summary)\" "
                + "focusedRole=\(inspection?.focusedRoleSummary ?? "n/a") "
                + "resolvedRole=\(inspection?.resolvedRoleSummary ?? "n/a") "
                + "missing=\(inspection?.missingCapabilitySummary ?? "n/a")"
        }

        let textLength = context.precedingText.count + context.trailingText.count
        return "role=\(context.role)/\(context.subrole ?? "n/a") "
            + "selection=\(context.selection.location)+\(context.selection.length) "
            + "textLength=\(textLength) before=\(context.precedingText.count) after=\(context.trailingText.count) "
            + "secure=\(context.isSecure) sequence=\(context.focusChangeSequence) "
            + "caret=\(context.caretQuality.label):\(context.caretSource) "
            + "caretRect=\(formatRect(context.caretRect)) inputRect=\(formatOptionalRect(context.inputFrameRect)) "
            + "resolvedRole=\(inspection?.resolvedRoleSummary ?? "n/a") "
            + "missing=\(inspection?.missingCapabilitySummary ?? "n/a")"
    }

    func formatOptionalRect(_ rect: CGRect?) -> String {
        rect.map(formatRect) ?? "nil"
    }

    func formatRect(_ rect: CGRect) -> String {
        String(
            format: "(x=%.0f,y=%.0f,w=%.0f,h=%.0f)",
            rect.origin.x,
            rect.origin.y,
            rect.width,
            rect.height
        )
    }
}
