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
            "Focus snapshot changed: app=\(snapshot.applicationName) capability=\(snapshot.capability.shortLabel)"
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
            // The user is now on a new editable surface and is likely to type soon. Prime the
            // selected engine in the background so weight loading and instruction tokenization
            // happen before the first real `respond` instead of inside its critical path. Llama's
            // default `prewarm` is a no-op, so this call is FM-only by design.
            prewarmEngineForCurrentField(rawContext: focusedContext)
        }

        if overlayState.isVisible {
            hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
        }
    }

    /// Fire-and-forget warmup that builds a minimal request shape for the current focus and asks
    /// the routed engine to prime itself. Generation 0 is intentional — prewarm requests must not
    /// burn real generation numbers, because those drive the stale-result drop logic.
    private func prewarmEngineForCurrentField(rawContext: FocusedInputSnapshot) {
        let settings = settingsSnapshot
        let configuration = configuration
        let suggestionEngine = suggestionEngine
        Task { @MainActor [weak self] in
            // If the coordinator has been torn down (app shutdown), skip prewarm entirely.
            // Using `guard let self` instead of the optional chain prevents prewarm from
            // racing past a missed cache-reset barrier when self has gone away.
            guard let self else { return }
            // Honor the cache-reset barrier so prewarm always runs *after* the engine has dropped
            // the session that belongs to the previous editing context. Otherwise the reset can
            // null the freshly primed session out from under us.
            await self.awaitCachedGenerationContextResetIfNeeded()
            let prewarmContext = FocusedInputContext(snapshot: rawContext, generation: 0)
            let request = SuggestionRequestFactory.buildRequest(
                context: prewarmContext,
                settings: settings,
                configuration: configuration
            ).request
            await suggestionEngine.prewarm(for: request)
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
            return acceptCurrentSuggestion(originalEvent: event)
        }

        if event.kind == .fullAcceptance {
            return acceptEntireSuggestion(originalEvent: event)
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
            // Same Chromium AX-publish race as the with-session paths below: the CGEvent tap runs
            // *before* the host app processes the keystroke, so a synchronous `refreshNow()` here
            // reads pre-keystroke text and feeds it into generation. The result is a suggestion
            // that looks like the typed character was ignored — see
            // `schedulePredictionAfterHostPublishDelay` for the full rationale.
            schedulePredictionAfterHostPublishDelay()
        }

        return false
    }

    /// Maximum wall time we'll wait for the host app to publish post-keystroke AX before giving
    /// up and generating against whatever's there. Chosen empirically: long enough to cover
    /// Chrome's slower contenteditable publish on a busy page, short enough that the user can
    /// always type ahead without the rescheduled suggestion feeling stuck.
    private static let hostPublishWaitCeilingMs = 400

    /// Interval between AX polls while waiting for the host publish. Same order of magnitude as
    /// the focus poll itself (default 80ms) but tighter so we catch the publish promptly without
    /// burning CPU on AX queries that are themselves 5–15ms each.
    private static let hostPublishPollIntervalMs = 30

    /// Schedules a fresh prediction once the host app has actually published the new
    /// contenteditable text to AX. The previous fix waited a fixed 150ms — see PR #376 — but the
    /// logs in #381 showed Chromium's publish lag can exceed that ceiling on a busy page, so the
    /// rescheduled generation still read pre-keystroke text and produced a suggestion that looked
    /// like Cotabby swallowed the character.
    ///
    /// We now snapshot the AX state at keystroke time (focused element identity, preceding text,
    /// selection) and poll `focusModel` until the snapshot actually moves on. The poll is capped
    /// at `hostPublishWaitCeilingMs` so a silent host can't hang the pipeline — once the cap is
    /// reached we generate against whatever's there, matching the old fixed-delay behavior.
    /// `schedulePrediction()` internally `replaceDebouncedWork`s, so back-to-back keystrokes
    /// still collapse cleanly.
    private func schedulePredictionAfterHostPublishDelay() {
        let baseline = focusModel.snapshot.context
        pollForHostPublish(
            baselineText: baseline?.precedingText,
            baselineElementID: baseline?.elementIdentifier,
            baselineSelectionLocation: baseline?.selection.location,
            elapsedMs: 0
        )
    }

    /// Drives the snapshot-changed gate. Reads the live focus snapshot, fires `schedulePrediction`
    /// as soon as any of the captured baseline fields move on, and otherwise tail-calls itself
    /// after `hostPublishPollIntervalMs` until the ceiling is hit.
    private func pollForHostPublish(
        baselineText: String?,
        baselineElementID: String?,
        baselineSelectionLocation: Int?,
        elapsedMs: Int
    ) {
        focusModel.refreshNow()
        let currentContext = focusModel.snapshot.context

        // No focus context at all means the user moved away from any editable field — let
        // `schedulePrediction` and its downstream guards handle the disabled / unsupported state.
        let textChanged = currentContext?.precedingText != baselineText
        let elementChanged = currentContext?.elementIdentifier != baselineElementID
        let selectionChanged = currentContext?.selection.location != baselineSelectionLocation
        if textChanged || elementChanged || selectionChanged {
            schedulePrediction()
            return
        }

        // Ceiling: stop polling and generate anyway. Without this fallback a host that genuinely
        // produces no AX change (rare but possible — e.g. dead-key composition) would never get
        // its next prediction.
        let nextElapsed = elapsedMs + Self.hostPublishPollIntervalMs
        guard nextElapsed < Self.hostPublishWaitCeilingMs else {
            schedulePrediction()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.hostPublishPollIntervalMs)) { [weak self] in
            self?.pollForHostPublish(
                baselineText: baselineText,
                baselineElementID: baselineElementID,
                baselineSelectionLocation: baselineSelectionLocation,
                elapsedMs: nextElapsed
            )
        }
    }

    func handleSuppressedSyntheticInput() {
        logStage(
            "suppressed-synthetic-input",
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: "Ignored Cotabby's own synthetic key event."
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
                schedulePredictionAfterHostPublishDelay()
            }
            return false

        case .shortcutMutation:
            invalidateActiveSuggestion(
                reason: "Overlay hidden because a shortcut changed the text and invalidated the current suggestion.",
                clearDiagnostics: false
            )
            if event.shouldSchedulePrediction {
                schedulePredictionAfterHostPublishDelay()
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
