import AppKit
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Suggestion acceptance, live-session advancement, overlay presentation, and debug logging.
/// This is the "user sees it or commits it" end of the coordinator.
extension SuggestionCoordinator {
    // MARK: - Acceptance and Session Reconciliation

    /// Accepts the next word of the current suggestion.
    func acceptCurrentSuggestion() -> Bool {
        acceptSuggestion(fullText: false, keyName: "Tab")
    }

    /// Accepts the entire remaining suggestion at once.
    func acceptEntireSuggestion() -> Bool {
        acceptSuggestion(fullText: true, keyName: "full-accept")
    }

    /// Shared acceptance path used by both word-by-word and full acceptance.
    private func acceptSuggestion(
        fullText: Bool,
        keyName: String
    ) -> Bool {
        let snapshot = focusModel.snapshot

        guard permissionManager.inputMonitoringGranted else {
            return passTabThrough(
                reason: "Input Monitoring permission is required before Cotabby can accept suggestions."
            )
        }

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            return passTabThrough(reason: snapshot.capability.summary)
        }

        // Gate on the live session, not on `state`. A background refresh (notably the visual-context
        // path that calls `schedulePrediction` once OCR finishes) flips `state` to `.debouncing`
        // while the previous suggestion is still buffered and its overlay is still on screen — and
        // the accept tap is still installed because the overlay is visible. Gating on `.ready`
        // would let the key fall through even though the user sees ghost text they can still
        // accept. `validateSessionForAcceptance` still rejects the accept if the session no longer
        // reconciles with the live AX state.
        guard interactionState.activeSession != nil else {
            return passTabThrough(
                reason: "Key passed through because no valid suggestion was ready."
            )
        }

        // `acceptEntireSuggestion` forces the full-acceptance path regardless of granularity so the
        // dedicated full-accept key stays a per-press override. `acceptCurrentSuggestion` honors
        // the user-selected granularity for the primary accept key.
        let primaryGranularity = settingsSnapshot.acceptanceGranularity
        let preparation: SuggestionAcceptancePreparation
        if fullText || primaryGranularity == .full {
            preparation = interactionState.prepareFullAcceptance(from: rawContext, overlayState: overlayState)
        } else {
            preparation = interactionState.prepareAcceptance(
                from: rawContext,
                overlayState: overlayState,
                granularity: primaryGranularity,
                autoAcceptTrailingPunctuation: settingsSnapshot.autoAcceptTrailingPunctuation
            )
        }

        let liveContext: FocusedInputContext
        let sessionForAcceptance: ActiveSuggestionSession
        let acceptedChunk: String
        switch preparation {
        case let .ready(preparedLiveContext, preparedSession, preparedAcceptedChunk):
            liveContext = preparedLiveContext
            sessionForAcceptance = preparedSession
            acceptedChunk = preparedAcceptedChunk

        case let .invalid(reason):
            return passTabThrough(reason: reason)
        }

        // Reconcile the word boundary against the *live* preceding text instead of trusting the
        // leading space baked into the suggestion at generation time — that decision goes stale when
        // the user types the separating space themselves, producing a double space on accept. The
        // session still advances by the full `acceptedChunk`; the whitespace we skip typing is the
        // field's own, so the post-insertion consumed-suffix accounting still lines up.
        let insertionChunk = SuggestionSessionReconciler.insertionChunk(
            forAcceptedChunk: acceptedChunk,
            precedingText: liveContext.precedingText
        )

        // An empty chunk means the accepted span was entirely a boundary space the field already
        // supplies: advance the session without synthesizing a keystroke.
        if !insertionChunk.isEmpty, !suggestionInserter.insert(insertionChunk) {
            let message = suggestionInserter.lastErrorMessage ?? "Suggestion insertion failed."
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because suggestion insertion failed.")
            state = .idle
            logStage(
                "insert-failed",
                workID: currentWorkID,
                generation: liveContext.generation,
                message: message,
                normalizedOutput: insertionChunk
            )
            return false
        }

        recordAcceptedWords(from: acceptedChunk)

        cancelPredictionWork()

        switch interactionState.commitAcceptedChunk(
            acceptedChunk,
            liveContext: liveContext,
            session: sessionForAcceptance
        ) {
        case .exhausted:
            latestGenerationNumber = liveContext.generation
            clearSuggestion(clearDiagnostics: false)
            hideOverlay(reason: "Overlay hidden because \(keyName) accepted the final suggestion chunk.")
            latestAcceptanceAction = "Accepted final chunk with \(keyName)."
            state = .idle
            // Remember what we just committed and the text it followed. `apply` consumes this to drop
            // a regeneration that only re-proposes the same tail before the host publishes the insert
            // (see the `schedulePredictionAfterHostPublishDelay` rationale below).
            lastAcceptedTail = AcceptedSuggestionTail(text: acceptedChunk, precedingText: liveContext.precedingText)
            logStage(
                "\(keyName)-accepted-final-chunk",
                workID: currentWorkID,
                generation: liveContext.generation,
                message: "Inserted the final suggestion chunk and queued a refresh.",
                normalizedOutput: acceptedChunk
            )
            // Wait for the host to actually publish the inserted text before regenerating. A bare
            // `schedulePrediction()` here reads pre-insertion AX in Chromium editors (the publish lags
            // the synthetic keystroke), so the model re-proposes the word just accepted and the next
            // accept re-inserts it. That is the final-word accept/regenerate/accept loop reported as
            // the suggestion "flickering" without committing. Polling until the insert surfaces (the
            // same path typing uses) makes the regeneration read the settled text and return a genuine
            // next suggestion, or nothing.
            schedulePredictionAfterHostPublishDelay()
            return true

        case let .advanced(advancedSession, _):
            latestGenerationNumber = liveContext.generation
            applySessionDiagnostics(advancedSession, acceptanceAction: "Accepted next chunk with \(keyName).")
            state = .ready(text: advancedSession.remainingText, latency: advancedSession.latency)
            let isRTL = TextDirectionDetector.isRightToLeft(liveContext.precedingText)
            let predictedCaret = Self.predictedCaretRect(
                after: insertionChunk,
                oldCaretRect: liveContext.caretRect,
                caretQuality: liveContext.caretQuality,
                observedCharWidth: liveContext.observedCharWidth,
                isRightToLeft: isRTL
            )
            presentOverlay(
                text: advancedSession.remainingText,
                at: predictedCaret,
                context: liveContext,
                isRightToLeft: isRTL
            )
            schedulePostInsertionRefresh()
            logStage(
                "\(keyName)-accepted-chunk",
                workID: currentWorkID,
                generation: liveContext.generation,
                message: "Inserted the next suggestion chunk and kept the remaining tail active.",
                normalizedOutput: acceptedChunk
            )
            return true
        }
    }

    /// Returns control of the accept key to the host app and clears stale suggestion UI.
    ///
    /// `InputMonitor` calls this from the consuming tap before returning a callback result. A `false`
    /// return tells that tap to pass the original key event through naturally, so no synthetic
    /// replay is needed.
    func passTabThrough(reason: String) -> Bool {
        let generation = latestGenerationNumber
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .idle
        logStage(
            "tab-passed-through",
            workID: currentWorkID,
            generation: generation,
            message: reason
        )
        return false
    }

    /// Advances the active session from the user's directly typed characters when they match the
    /// next expected tail exactly. This avoids a wasteful regeneration for text the user already
    /// committed to the field themselves.
    func advanceActiveSessionIfTypedCharactersMatch(_ typedCharacters: String, session: ActiveSuggestionSession) -> Bool {
        guard let advancedSession = interactionState.advanceIfTypedCharactersMatch(
            typedCharacters,
            expectedSession: session
        ) else {
            return false
        }

        cancelPredictionWork()
        applySessionDiagnostics(advancedSession, acceptanceAction: "User typed the next expected characters.")

        if advancedSession.isExhausted {
            completeActiveSuggestion(
                reason: "Overlay hidden because the user typed through the rest of the suggestion.",
                scheduleNextPrediction: true,
                stage: "typed-match-exhausted",
                message: "The user typed the remaining suggestion characters exactly.",
                acceptanceAction: "User typed through the rest of the suggestion."
            )
            return true
        }

        state = .ready(text: advancedSession.remainingText, latency: advancedSession.latency)
        presentOverlay(
            text: advancedSession.remainingText,
            at: session.baseContext.caretRect,
            context: session.baseContext
        )
        logStage(
            "typed-match-advanced",
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: "User typing matched the active suggestion tail exactly.",
            normalizedOutput: advancedSession.remainingText
        )
        return true
    }

    func invalidateActiveSuggestion(
        reason: String,
        clearDiagnostics: Bool = true
    ) {
        CotabbyLogger.suggestion.debug("Invalidating active suggestion: \(reason)")
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: clearDiagnostics)
        hideOverlay(reason: reason)
        state = .idle
    }

    func completeActiveSuggestion(
        reason: String,
        scheduleNextPrediction: Bool,
        stage: String,
        message: String,
        acceptanceAction: String
    ) {
        let generation = latestGenerationNumber
        clearSuggestion(clearDiagnostics: false)
        latestAcceptanceAction = acceptanceAction
        hideOverlay(reason: reason)
        state = .idle
        logStage(stage, workID: currentWorkID, generation: generation, message: message)

        if scheduleNextPrediction {
            schedulePrediction()
        }
    }

    func applySessionDiagnostics(_ session: ActiveSuggestionSession, acceptanceAction: String?) {
        latestSuggestionPreview = session.remainingText
        latestFullSuggestionPreview = session.fullText
        latestRemainingSuggestionPreview = session.remainingText
        latestAcceptedCharacterCount = session.acceptedCount
        latestRemainingCharacterCount = session.remainingCount
        if let acceptanceAction {
            latestAcceptanceAction = acceptanceAction
        }
    }

    /// Updates the global productivity counter from text accepted via Tab.
    func recordAcceptedWords(from acceptedChunk: String) {
        let acceptedWordCount = SuggestionSessionReconciler.acceptedWordCount(in: acceptedChunk)
        guard acceptedWordCount > 0 else {
            return
        }

        totalTabAcceptedWordCount += acceptedWordCount
        userDefaults.set(totalTabAcceptedWordCount, forKey: Self.totalTabAcceptedWordCountDefaultsKey)
    }

    // MARK: - Caret Prediction

    /// Estimates the caret rect after inserting a chunk by shifting the old caret in the text
    /// direction. LTR shifts right; RTL shifts left.
    /// When `observedCharWidth` is available (measured from real AX child frames), we use it
    /// directly — this matches the target app's actual font. Falls back to NSFont measurement.
    static func predictedCaretRect(
        after insertedChunk: String,
        oldCaretRect: CGRect,
        caretQuality: CaretGeometryQuality,
        observedCharWidth: CGFloat?,
        isRightToLeft: Bool = false
    ) -> CGRect {
        let measuredWidth = predictedChunkWidth(
            insertedChunk: insertedChunk,
            observedCharWidth: observedCharWidth
        )
        let chunkWidth: CGFloat

        switch caretQuality {
        case .exact, .derived:
            chunkWidth = measuredWidth

        case .estimated:
            // Estimated caret geometry is already low-confidence. If we apply the full predicted
            // shift after every Tab, the overlay can visibly march away from the real caret before
            // AX catches up. We still keep this path separate from trusted geometry, but we apply
            // an explicit upward bias here because the previous tuning was visibly lagging in
            // larger editors that only expose coarse AXFrame fallbacks.
            let estimatedPredictionBias: CGFloat = 1.5
            let conservativeCap = max(
                CGFloat(34) * estimatedPredictionBias,
                CGFloat(insertedChunk.count) * 13 * estimatedPredictionBias
            )
            chunkWidth = min(
                max(measuredWidth * 0.91 * estimatedPredictionBias, 14 * estimatedPredictionBias),
                conservativeCap
            )
        }

        let shift = isRightToLeft ? -chunkWidth : chunkWidth
        return CGRect(
            x: oldCaretRect.origin.x + shift,
            y: oldCaretRect.origin.y,
            width: oldCaretRect.width,
            height: oldCaretRect.height
        )
    }

    private static func predictedChunkWidth(
        insertedChunk: String,
        observedCharWidth: CGFloat?
    ) -> CGFloat {
        if let observed = observedCharWidth {
            return observed * CGFloat(insertedChunk.count)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        return (insertedChunk as NSString).size(withAttributes: attrs).width
    }

    /// Gives the host app ~30ms to process the synthetic keystroke, then forces an AX snapshot
    /// so the overlay snaps to the real caret position without waiting for the 250ms poll.
    func schedulePostInsertionRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.focusModel.refreshNow()
            self.reconcileActiveSession(with: self.focusModel.snapshot)
        }
    }

    // MARK: - Overlay and Logging

    func presentOverlay(
        text: String,
        at caretRect: CGRect,
        context: FocusedInputContext,
        isRightToLeft: Bool = false
    ) {
        let geometry = SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: context.inputFrameRect,
            caretQuality: context.caretQuality,
            observedCharWidth: context.observedCharWidth,
            isRightToLeft: isRightToLeft,
            focusChangeSequence: context.focusChangeSequence
        )
        if let message = overlayPresenter.present(
            text: text,
            geometry: geometry,
            previousState: overlayState
        ) {
            latestOverlayMessage = message
        }
    }

    func hideOverlay(reason: String) {
        latestOverlayMessage = overlayPresenter.hide(reason: reason)
    }

    func logStage(
        _ stage: String,
        workID: UInt64,
        generation: UInt64? = nil,
        message: String,
        prompt: String? = nil,
        rawOutput: String? = nil,
        normalizedOutput: String? = nil
    ) {
        latestStageMessage = message
        logger.logStage(
            stage,
            workID: workID,
            generation: generation,
            message: message,
            prompt: prompt,
            rawOutput: rawOutput,
            normalizedOutput: normalizedOutput
        )

        // Mirror the stage into the structured JSONL stream so an AI debugger can join every event
        // touching one suggestion via `request_id`. `latestRequestID` is set when `+Prediction`
        // builds the request and cleared between sessions; logs outside an active request still
        // carry a placeholder so the field shape is stable for `jq`.
        var metadata: Logger.Metadata = [
            "stage": .string(stage),
            "work_id": .stringConvertible(workID),
            "request_id": .string(latestRequestID ?? "req_none")
        ]
        if let generation {
            metadata["generation"] = .stringConvertible(generation)
        }
        CotabbyLogger.suggestion.debug(.init(stringLiteral: message), metadata: metadata)
    }
}
