import Foundation
import Logging

/// File overview:
/// Debounce, generation, stale-result handling, and visual-context-triggered rescheduling.
/// This is the async half of the coordinator's state machine.
extension SuggestionCoordinator {
    // MARK: - Prediction Pipeline

    func schedulePrediction() {
        if let disabledReason = currentDisabledReason(focusSnapshot: focusModel.snapshot) {
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

        if let disabledReason = currentDisabledReason(focusSnapshot: snapshot) {
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

        // Typo gate: before building a normal continuation, check the current word with
        // NSSpellChecker. A misspelled word either suppresses the continuation (so completions never
        // pile onto a broken word) or, when corrections are enabled, presents a native spell-checker
        // fix the user can accept to replace the typo. Native correction is instant and needs no
        // model generation, so it is handled synchronously and returns before any request runs.
        if handleTypoGate(rawContext: rawContext, workID: workID) {
            return
        }

        let context = interactionState.materializeContext(from: rawContext)
        let visualContextSummary = visualContextCoordinator.excerpt(for: context)
        let rawClipboard = settingsSnapshot.isClipboardContextEnabled
            ? clipboardContextProvider.currentContext()
            : nil
        // Same bounded window the downstream distiller sees, so the relevance gate and the
        // per-line filter can't disagree about what "shares tokens with the prefix" means.
        let truncatedPrefix = SuggestionRequestFactory.truncatedPromptPrefix(
            from: rawContext.precedingText,
            configuration: configuration,
            engine: settingsSnapshot.selectedEngine
        )
        let clipboardContext = clipboardRelevanceFilter.filter(
            clipboard: rawClipboard,
            pasteboardChangeCount: clipboardContextProvider.currentChangeCount,
            precedingText: truncatedPrefix
        )
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
        latestRequestID = request.requestID

        state = .generating
        logStage(
            "generating",
            workID: workID,
            generation: context.generation,
            message: "Requesting a completion for \(context.elementIdentifier).",
            prompt: requestBuildResult.promptPreview
        )

        dispatchGeneration(request: request, workID: workID)
    }

    /// Runs the engine generation for `request` as the replaceable work for `workID`, applying the
    /// result (or failure) only while it is still the current work. Extracted from
    /// `generateFromCurrentFocus` so that function stays within the project's complexity budget.
    private func dispatchGeneration(request: SuggestionRequest, workID: UInt64) {
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

    /// Runs the typo gate for the current word. Returns `true` when it handled the cycle (suppressed
    /// the continuation or presented a correction) and the caller should stop; `false` to proceed
    /// with a normal continuation. Kept separate so `generateFromCurrentFocus` stays within the
    /// project's cyclomatic-complexity budget.
    private func handleTypoGate(rawContext: FocusedInputSnapshot, workID: UInt64) -> Bool {
        switch TypoGate.resolve(
            precedingText: rawContext.precedingText,
            suppressCompletionsOnTypo: settingsSnapshot.suppressCompletionsOnTypo,
            offerTypoCorrections: settingsSnapshot.offerTypoCorrections,
            isTypo: { spellChecker.isTypo($0) },
            // Correction word: SymSpell (frequency-ranked, edit distance ≤ 2) first; fall back to the
            // NSSpellChecker guess while SymSpell's index is still loading or when it has no match.
            bestCorrection: { symSpellCorrector.bestCorrection(for: $0) ?? spellChecker.bestCorrection(for: $0) }
        ) {
        case .proceed:
            return false
        case .suppress:
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the current word looks misspelled.")
            state = .idle
            logStage(
                "typo-suppressed",
                workID: workID,
                message: "Skipped generation because the current word looks misspelled."
            )
            return true
        case let .correct(word, correctedWord):
            presentCorrection(
                typoWord: word,
                correctedWord: correctedWord,
                rawContext: rawContext,
                workID: workID
            )
            return true
        }
    }

    /// Presents a native spell-checker correction as a replace-the-word suggestion, with no model
    /// generation. The session carries `.correction(typoWord:)` so the acceptance
    /// path swaps the typo for the fix, and the overlay renders green so the user can tell at a
    /// glance that accepting replaces their last word rather than extending it.
    private func presentCorrection(
        typoWord: String,
        correctedWord: String,
        rawContext: FocusedInputSnapshot,
        workID: UInt64
    ) {
        let liveContext = interactionState.materializeContext(from: rawContext)
        latestGenerationNumber = liveContext.generation
        latestLatencyMilliseconds = 0
        let session = interactionState.startSession(
            fullText: correctedWord,
            liveContext: liveContext,
            latency: 0,
            kind: .correction(typoWord: typoWord)
        )
        applySessionDiagnostics(session, acceptanceAction: "Offered a correction for \"\(typoWord)\".")
        state = .ready(text: session.remainingText, latency: 0)
        presentOverlay(
            text: session.remainingText,
            at: liveContext.caretRect,
            context: liveContext,
            isRightToLeft: TextDirectionDetector.isRightToLeft(liveContext.precedingText),
            isCorrection: true
        )
        logStage(
            "typo-correction-ready",
            workID: workID,
            generation: liveContext.generation,
            message: "Offered a native spell-checker correction for the current word.",
            normalizedOutput: correctedWord
        )
    }

    /// Promotes a generated result to `ready` only when it is still fresh for the current field.
    func apply(result: SuggestionResult, workID: UInt64) async {

        guard workController.isCurrent(workID) else {

            return
        }

        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        if let disabledReason = currentDisabledReason(focusSnapshot: snapshot) {

            disablePredictions(reason: disabledReason)
            return
        }

        guard let rawContext = snapshot.context else {

            disablePredictions(reason: snapshot.capability.summary)
            return
        }

        let liveContext = interactionState.materializeContext(from: rawContext)

        // Consume the tail recorded by a final-chunk accept. It gets exactly one shot to be
        // recognized as a stale echo on the regeneration scheduled right after acceptance.
        let pendingAcceptedTail = lastAcceptedTail
        lastAcceptedTail = nil

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

        // A regeneration that only re-proposes the just-accepted tail while the field still shows the
        // pre-acceptance text means our insert has not published yet. Drop it so the next accept can't
        // re-insert the same word and spin the final-word loop.
        if let pendingAcceptedTail,
           SuggestionSessionReconciler.isStaleAcceptanceEcho(
               resultText: result.text,
               acceptedChunk: pendingAcceptedTail.text,
               currentPrecedingText: liveContext.precedingText,
               acceptedPrecedingText: pendingAcceptedTail.precedingText
           ) {
            clearSuggestion(clearDiagnostics: false)
            hideOverlay(reason: "Overlay hidden because the regeneration only echoed the just-accepted text before the host published it.")
            state = .idle
            logStage(
                "stale-accept-echo",
                workID: workID,
                generation: result.generation,
                message: "Dropped a regeneration that re-proposed the just-accepted tail before the host published the insert.",
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
            context: liveContext,
            isRightToLeft: TextDirectionDetector.isRightToLeft(liveContext.precedingText)
        )
        logStage(
            "ready",
            workID: workID,
            generation: result.generation,
            message: "Accepted a non-empty normalized suggestion.",
            rawOutput: result.rawText,
            normalizedOutput: result.text
        )

        // If the user pressed Tab while this continuation was still regenerating, accept its first
        // word now so rapid Tabbing keeps inserting words across the exhaustion boundary instead of
        // stalling once the previous suggestion ran out. No-op when nothing was queued.
        flushQueuedPostExhaustionAcceptIfNeeded()
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
        let disabledReason = currentDisabledReason(focusSnapshot: focusModel.snapshot)

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
        guard let activeSession = interactionState.activeSession else {
            if overlayState.isVisible {
                hideOverlay(reason: "Overlay hidden because no ready suggestion remains.")
            }
            return
        }

        // Corrections are accept-or-dismiss, never partially consumed: the corrected word is not a
        // continuation of the preceding text, so the normal reconciler would mis-advance it the
        // moment the user types a character that happens to match the fix. Keep the offer only while
        // the field is unchanged; any edit drops it and the next prediction re-evaluates the new word.
        if activeSession.kind.isCorrection {
            reconcileCorrectionSession(activeSession, with: snapshot)
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
            applyValidReconciliation(
                liveContext: liveContext,
                reconciledSession: reconciledSession,
                advancement: advancement
            )

        case let .invalid(reason):
            invalidateActiveSuggestion(reason: reason)
        }
    }

    /// Applies a `.valid` reconciliation result: completes an exhausted session, or re-renders the
    /// remaining tail (subject to the stability gate). Extracted from `reconcileActiveSession` so that
    /// function stays within the project's cyclomatic-complexity budget after the correction branch.
    private func applyValidReconciliation(
        liveContext: FocusedInputContext,
        reconciledSession: ActiveSuggestionSession,
        advancement: SuggestionSessionAdvancement?
    ) {
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
        // Reconciliation runs both for legitimate context changes (window drag, field switch,
        // user typing through the tail) and for the +30ms post-insertion AX refresh that fires
        // after every Tab accept. In the post-insertion case the underlying state has not
        // meaningfully changed (the overlay already shows the right tail at the predicted
        // caret), but AX commonly returns a slightly different `caretRect` / `observedCharWidth`
        // than the predicted pair. Re-rendering against those drifted measurements is what
        // causes the visible one-frame "shift left and down then snap back" on accept. Hold the
        // existing geometry whenever the field, text, and on-screen field bounds have not
        // materially moved; the gate below still re-anchors on legitimate context changes.
        if SuggestionOverlayStabilityGate.shouldRePresent(
            currentOverlay: overlayState,
            newText: reconciledSession.remainingText,
            newInputFrameRect: liveContext.inputFrameRect,
            newFocusChangeSequence: liveContext.focusChangeSequence
        ) {
            presentOverlay(
                text: reconciledSession.remainingText,
                at: liveContext.caretRect,
                context: liveContext,
                isRightToLeft: TextDirectionDetector.isRightToLeft(liveContext.precedingText)
            )
        }
        if let advancement {
            logStage(
                advancement.stage,
                workID: currentWorkID,
                generation: liveContext.generation,
                message: advancement.message,
                normalizedOutput: reconciledSession.remainingText
            )
        }
    }

    /// Keeps a native correction offer on screen only while the field is unchanged. A correction is
    /// a snapshot in time: the instant the user edits (or switches apps/fields), the offer is stale,
    /// so we drop it and let the next prediction re-run the typo gate against the new current word.
    /// We deliberately do not advance or re-anchor it, because a corrected word is not a continuation
    /// of the preceding text.
    private func reconcileCorrectionSession(_ session: ActiveSuggestionSession, with snapshot: FocusSnapshot) {
        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            // Tolerate the transient post-insertion AX-sync gap the same way the continuation path
            // does, so a single empty poll right after our own edit does not flap the overlay.
            if interactionState.isAwaitingPostInsertionSync {
                return
            }
            invalidateActiveSuggestion(reason: snapshot.capability.summary)
            return
        }

        guard case let .correction(typoWord) = session.kind else {
            invalidateActiveSuggestion(reason: "Overlay hidden because the correction session was invalid.")
            return
        }

        // Keep the offer while the live trailing word (tolerating one trailing space the user just
        // typed) is still the exact typo we offered to fix, in the same app. This is what makes the
        // green correction survive a space: the word is unchanged, so we keep showing it as
        // Tab-acceptable. Any other edit — typing more, a second space, deleting, switching apps —
        // drops it, and the next prediction re-runs the gate for the new current word.
        let liveWord = CurrentWordExtractor.extractTrailingWord(from: rawContext.precedingText)?.result.word
        if liveWord == typoWord, rawContext.processIdentifier == session.baseContext.processIdentifier {
            return
        }
        invalidateActiveSuggestion(
            reason: "Overlay hidden because the field changed after a correction was offered."
        )
    }

    /// The single marshalling point for `SuggestionAvailabilityEvaluator.disabledReason`: every gate
    /// in the input and prediction paths shares the same settings, permission, and per-domain inputs,
    /// and varies only by which focus snapshot it is checking. Returns the user-facing disable reason,
    /// or nil when predictions are allowed for `focusSnapshot`.
    func currentDisabledReason(focusSnapshot: FocusSnapshot) -> String? {
        SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            disabledDomains: PerDomainDisableSettings.disabledDomains(),
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: focusSnapshot
        )
    }

    /// Fully disables prediction, clears cached context, and updates UI messaging with the cause.
    func disablePredictions(reason: String) {
        CotabbyLogger.suggestion.debug("Predictions disabled: \(reason)")
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
        // Drop any pending accepted-tail guard whenever the suggestion state is torn down (user
        // typed, focus changed, predictions disabled). The final-chunk accept re-sets it afterward.
        lastAcceptedTail = nil
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
            // Clear so the next session's terminal logStage doesn't carry the previous
            // request_id forward. `+Acceptance.logStage` falls back to "req_none" on nil,
            // preserving the join-key contract documented on `latestRequestID`.
            latestRequestID = nil
        }
    }

    /// Cancels debounce/generation tasks and advances the work id so late completions are ignored.
    func cancelPredictionWork() {
        hostPublishPollGeneration &+= 1
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
