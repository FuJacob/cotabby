import Foundation

/// File overview:
/// Debounce, generation, stale-result handling, and visual-context-triggered rescheduling.
/// This is the async half of the coordinator's state machine.
extension SuggestionCoordinator {
    // MARK: - Prediction Pipeline

    func schedulePrediction() {
        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: focusModel.snapshot
        ) {
            disablePredictions(reason: disabledReason)
            return
        }

        // Task cancellation in Swift is cooperative, so we also use an explicit work id.
        // That gives us strict "latest request wins" semantics even if an old task wakes up late.
        let workID = workController.replaceDebouncedWork(
            delayMilliseconds: settingsSnapshot.debounceMilliseconds
        ) { [weak self] workID in
            await self?.generateFromCurrentFocus(workID: workID)
        }

        state = .debouncing
        logStage("debouncing", workID: workID, message: "Waiting \(settingsSnapshot.debounceMilliseconds)ms before generating.")
    }

    /// Refreshes focus after debounce, materializes a stable context, and starts generation.
    func generateFromCurrentFocus(workID: UInt64) async {
        guard workController.isCurrent(workID) else {
            return
        }

        await awaitCachedGenerationContextResetIfNeeded()
        guard workController.isCurrent(workID) else {
            return
        }

        // We intentionally re-read the latest focus snapshot here instead of trusting the earlier
        // key event, because the user may have switched apps or fields during the debounce window.
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: snapshot
        ) {
            disablePredictions(reason: disabledReason)
            return
        }

        guard let rawContext = snapshot.context else {
            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        guard SuggestionRequestFactory.shouldGenerateSuggestion(for: rawContext.precedingText) else {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the field has no typed text yet.")
            state = .idle
            return
        }

        let context = interactionState.materializeContext(from: rawContext)
        let visualContextSummary = visualContextCoordinator.excerpt(for: context)
        let clipboardContext = settingsSnapshot.isClipboardContextEnabled
            ? clipboardContextProvider.currentContext()
            : nil
        let requestBuildResult = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: settingsSnapshot,
            configuration: configuration,
            clipboardContext: clipboardContext,
            visualContextSummary: visualContextSummary
        )
        latestGenerationNumber = context.generation
        latestPromptPreview = requestBuildResult.promptPreview
        latestRawModelOutput = nil
        let request = requestBuildResult.request

        state = .generating
        logStage(
            "generating",
            workID: workID,
            generation: context.generation,
            message: "Requesting a completion for \(context.elementIdentifier).",
            prompt: requestBuildResult.promptPreview
        )

        workController.replaceGenerationWork(for: workID) { [weak self] in
            guard let self else {
                return
            }

            do {
                let result = try await suggestionEngine.generateSuggestion(for: request)
                guard !Task.isCancelled, self.workController.isCurrent(workID) else {
                    return
                }

                await apply(result: result, workID: workID)
            } catch SuggestionClientError.cancelled {
                return
            } catch {
                guard self.workController.isCurrent(workID) else {
                    return
                }

                await applyFailure(error.localizedDescription, workID: workID)
            }
        }
    }

    /// Promotes a generated result to `ready` only when it is still fresh for the current field.
    func apply(result: SuggestionResult, workID: UInt64) async {

        guard workController.isCurrent(workID) else {

            return
        }

        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: snapshot
        ) {

            disablePredictions(reason: disabledReason)
            return
        }

        guard let rawContext = snapshot.context else {

            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        let liveContext = interactionState.materializeContext(from: rawContext)

        // Generation numbers are our stale-result guard. If the text changed while the model was
        // thinking, we drop the answer instead of showing a suggestion for old content.
        guard liveContext.generation == result.generation else {

            latestRawModelOutput = SuggestionDebugLogger.debugPreview(result.rawText)
            logStage(
                "stale-drop",
                workID: workID,
                generation: result.generation,
                message: "Dropped stale result because live generation is \(liveContext.generation).",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            hideOverlay(reason: "Overlay hidden because a stale result was dropped.")
            return
        }

        latestRawModelOutput = SuggestionDebugLogger.debugPreview(result.rawText)

        guard !result.text.isEmpty else {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the model returned an empty continuation.")
            state = .idle
            logStage(
                "empty-result",
                workID: workID,
                generation: result.generation,
                message: "Model returned an empty or whitespace-only continuation after normalization.",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        guard liveContext.selection.length == 0 else {
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because text is selected.")
            state = .idle
            logStage(
                "selected-text",
                workID: workID,
                generation: result.generation,
                message: "Ignored the suggestion because the current field has selected text.",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        latestLatencyMilliseconds = Int(result.latency * 1000)
        latestGenerationNumber = liveContext.generation
        let session = interactionState.startSession(
            fullText: result.text,
            liveContext: liveContext,
            latency: result.latency
        )
        applySessionDiagnostics(session, acceptanceAction: "Generated new suggestion.")
        state = .ready(text: session.remainingText, latency: session.latency)

        presentOverlay(
            text: session.remainingText,
            at: liveContext.caretRect,
            inputFrameRect: liveContext.inputFrameRect,
            caretQuality: liveContext.caretQuality,
            observedCharWidth: liveContext.observedCharWidth
        )
        logStage(
            "ready",
            workID: workID,
            generation: result.generation,
            message: "Accepted a non-empty normalized suggestion.",
            rawOutput: result.rawText,
            normalizedOutput: result.text
        )
    }

    /// Converts a runtime or engine failure into visible coordinator state and clears stale UI.
    func applyFailure(_ message: String, workID: UInt64) async {
        guard workController.isCurrent(workID) else {
            return
        }

        clearSuggestion()
        hideOverlay(reason: "Overlay hidden because generation failed.")
        state = .failed(message)
        logStage("failed", workID: workID, generation: latestGenerationNumber, message: message)
    }

    // MARK: - Coordinator State Reset

    /// Recomputes whether prediction should be enabled based on current permissions and focus support.
    func reconcileWithCurrentEnvironment() {
        let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: focusModel.snapshot
        )

        if disabledReason == nil {
            if case .disabled = state {
                state = .idle
            }
        } else if let disabledReason {
            disablePredictions(reason: disabledReason)
        }
    }

    /// Reconciles the active suggestion session with the latest live AX context.
    /// This is the heart of partial acceptance: a text change is not automatically "stale" anymore.
    /// It may instead mean "the user consumed the next expected part of the suggestion."
    func reconcileActiveSession(with snapshot: FocusSnapshot) {
        guard interactionState.activeSession != nil else {
            if overlayState.isVisible {
                hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
            }
            return
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            // Browser-based editors can transiently report "no usable text field" for a single AX
            // poll right after we synthesize accepted text. During that narrow post-insertion sync
            // window, keep the active session alive and wait for the next settled snapshot.
            if interactionState.isAwaitingPostInsertionSync {
                return
            }
            invalidateActiveSuggestion(reason: snapshot.capability.summary)
            return
        }

        guard let reconciliation = interactionState.reconcileActiveSession(with: rawContext) else {
            invalidateActiveSuggestion(reason: "Overlay hidden because no ready suggestion remains.")
            return
        }

        switch reconciliation {
        case let .valid(liveContext, reconciledSession, advancement):
            latestGenerationNumber = liveContext.generation
            applySessionDiagnostics(reconciledSession, acceptanceAction: advancement?.actionSummary ?? latestAcceptanceAction)

            if reconciledSession.isExhausted {
                completeActiveSuggestion(
                    reason: "Overlay hidden because the active suggestion was fully consumed.",
                    scheduleNextPrediction: true,
                    stage: advancement?.exhaustionStage ?? "session-exhausted",
                    message: advancement?.exhaustionMessage ?? "The active suggestion was fully consumed.",
                    acceptanceAction: advancement?.actionSummary ?? "Suggestion tail was fully consumed."
                )
                return
            }

            state = .ready(text: reconciledSession.remainingText, latency: reconciledSession.latency)
            presentOverlay(
                text: reconciledSession.remainingText,
                at: liveContext.caretRect,
                inputFrameRect: liveContext.inputFrameRect,
                caretQuality: liveContext.caretQuality,
                observedCharWidth: liveContext.observedCharWidth
            )
            if let advancement {
                logStage(
                    advancement.stage,
                    workID: currentWorkID,
                    generation: liveContext.generation,
                    message: advancement.message,
                    normalizedOutput: reconciledSession.remainingText
                )
            }

        case let .invalid(reason):
            invalidateActiveSuggestion(reason: reason)
        }
    }

    /// Fully disables prediction, clears cached context, and updates UI messaging with the cause.
    func disablePredictions(reason: String) {
        cancelPredictionWork()
        resetCachedGenerationContext()
        visualContextCoordinator.cancel(resetState: true)
        interactionState.resetAll()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .disabled(reason)
        latestStageMessage = "Disabled: \(reason)"
    }

    /// Disables predictions without tearing down the visual context session.
    ///
    /// Transient disabled states — "text is selected", "secure field", brief "no focused element"
    /// between field switches — should not cancel an in-progress OCR pipeline. The visual context
    /// session is field-scoped and outlives individual prediction cycles; destroying it here would
    /// force a redundant re-capture when the user starts typing again.
    func disablePredictionsPreservingVisualContext(reason: String) {
        cancelPredictionWork()
        resetCachedGenerationContext()
        interactionState.resetAll()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .disabled(reason)
        latestStageMessage = "Disabled: \(reason)"
    }

    /// Clears the active suggestion and optionally preserves or drops diagnostic breadcrumbs.
    func clearSuggestion(clearDiagnostics: Bool = false) {
        latestSuggestionPreview = nil
        latestFullSuggestionPreview = nil
        latestRemainingSuggestionPreview = nil
        latestAcceptedCharacterCount = nil
        latestRemainingCharacterCount = nil
        latestAcceptanceAction = nil
        latestLatencyMilliseconds = nil
        interactionState.clearSuggestion()

        if clearDiagnostics {
            latestPromptPreview = nil
            latestRawModelOutput = nil
            latestGenerationNumber = nil
        }
    }

    /// Cancels debounce/generation tasks and advances the work id so late completions are ignored.
    func cancelPredictionWork() {
        workController.cancelAll()
    }

    /// Starts an ordered backend context reset without forcing synchronous input handlers to become
    /// async. `generateFromCurrentFocus` awaits this barrier before it builds the next request, so a
    /// reset caused by focus/settings changes cannot race with the following generation.
    func resetCachedGenerationContext() {
        pendingCacheReset?.task.cancel()
        cacheResetSequence &+= 1
        let sequence = cacheResetSequence
        let suggestionEngine = suggestionEngine
        let resetTask = Task { @MainActor in
            guard !Task.isCancelled else {
                return
            }

            await suggestionEngine.resetCachedGenerationContext()
        }
        pendingCacheReset = (sequence, resetTask)
    }

    func awaitCachedGenerationContextResetIfNeeded() async {
        guard let pendingCacheReset else {
            return
        }

        await pendingCacheReset.task.value

        if self.pendingCacheReset?.sequence == pendingCacheReset.sequence {
            self.pendingCacheReset = nil
        }
    }

    // MARK: - Visual Context

    /// Once screenshot context becomes ready, regenerate only if the user is still in the same
    /// field and there is enough typed text for a real inline completion request.
    func schedulePredictionForCurrentFocusIfPossible(matching identity: FocusedInputIdentity) {
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard SuggestionAvailabilityEvaluator.shouldSchedulePredictionWhenVisualContextBecomesReady(
            focusSnapshot: snapshot,
            matching: identity
        ) else {
            return
        }

        schedulePrediction()
    }
}
