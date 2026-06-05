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
        guard let activeSession = interactionState.activeSession else {
            return handleAcceptWithoutActiveSession(keyName: keyName)
        }

        // Corrections commit as a unit: Tab and the full-accept key both swap the typo'd word for
        // the corrected one in one gesture. Partial acceptance would be incoherent because the
        // corrected word and the typo can disagree on prefix length, so route to a dedicated path
        // before the continuation preparation below.
        if activeSession.kind.isCorrection {
            return acceptCorrection(session: activeSession, keyName: keyName, rawContext: rawContext)
        }

        // `acceptEntireSuggestion` forces the full-acceptance path so the dedicated full-accept key
        // stays a per-press override. `acceptCurrentSuggestion` honors the user-selected
        // granularity for the primary accept key — the granularity enum is intentionally limited to
        // partial modes (`.word`, `.phrase`), since whole-suggestion acceptance is exclusively the
        // dedicated full-accept key's job.
        let primaryGranularity = settingsSnapshot.acceptanceGranularity
        let preparation: SuggestionAcceptancePreparation
        if fullText {
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
            // Keep owning Tab while the continuation regenerates so a fast follow-up press is
            // swallowed and queued instead of leaking into the host app as a real Tab. Must run
            // *after* the `hideOverlay` above, which routes through `onStateChange(.hidden)` and
            // turns interception off; arming re-asserts it. See `armPostExhaustionAcceptance`.
            armPostExhaustionAcceptance()
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

    /// Handles the accept key when no buffered session exists. During the brief post-exhaustion
    /// regeneration window we keep owning the key and queue the press so rapid Tabbing keeps
    /// inserting words across the exhaustion boundary; otherwise the key passes through to the host.
    /// Extracted from `acceptSuggestion` to keep that function within the complexity budget.
    private func handleAcceptWithoutActiveSession(keyName: String) -> Bool {
        // A final-chunk accept tears the session down and regenerates the continuation
        // asynchronously (see the `.exhausted` branch). While that regen is in flight we keep owning
        // Tab instead of leaking it into the host app as a real Tab.
        if isPostExhaustionAcceptanceArmed {
            hasQueuedPostExhaustionAccept = true
            logStage(
                "\(keyName)-held-for-regen",
                workID: currentWorkID,
                generation: latestGenerationNumber,
                message: "Held a rapid \(keyName) during post-acceptance regeneration; "
                    + "the next continuation will accept its first word."
            )
            return true
        }
        return passTabThrough(
            reason: "Key passed through because no valid suggestion was ready."
        )
    }

    /// Commits a native correction by replacing the trailing typo with the corrected word in one
    /// suppressed synthetic burst (backspaces + insert). Returns true so the active accept tap
    /// consumes the key; false routes the key back to the host via `passTabThrough`.
    ///
    /// The delete length is recomputed from the LIVE current word, not the value captured when the
    /// correction was offered, so a keystroke that slipped in between can never make us delete the
    /// wrong number of characters: if the live word no longer matches what we offered to fix, we
    /// pass the key through instead of guessing.
    private func acceptCorrection(
        session: ActiveSuggestionSession,
        keyName: String,
        rawContext: FocusedInputSnapshot
    ) -> Bool {
        let correctedText = session.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correctedText.isEmpty else {
            return passTabThrough(reason: "Key passed through because the correction text was empty.")
        }

        // Confirm the live field still ends with the exact word we offered to correct (tolerating
        // one trailing space the user pressed after it). Comparing the word itself, not just its
        // length, closes the window where a keystroke between the last AX poll and this Tab swapped
        // in a different same-length word; if it diverged, pass the key through rather than delete
        // the wrong text.
        guard case let .correction(typoWord) = session.kind,
              let live = CurrentWordExtractor.extractTrailingWord(from: rawContext.precedingText),
              live.result.word == typoWord else {
            return passTabThrough(reason: "Key passed through because the word to correct changed.")
        }

        // Delete the typo plus any single trailing space the user added after it, then re-insert the
        // correction followed by that same space, so `nmae |` becomes `name |` with the spacing and
        // caret intact. `replace` deletes by UTF-16 unit (its parameter name and the emoji path's
        // contract), which equals the on-screen character count for the NFC text macOS AX delivers.
        let trailingSpaces = String(repeating: " ", count: live.trailingSpaceCount)
        let deletingUTF16Count = (typoWord as NSString).length + live.trailingSpaceCount
        guard suggestionInserter.replace(deletingUTF16Count: deletingUTF16Count, with: correctedText + trailingSpaces) else {
            let message = suggestionInserter.lastErrorMessage ?? "Correction insertion failed."
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because correction insertion failed.")
            state = .idle
            logStage(
                "correction-insert-failed",
                workID: currentWorkID,
                generation: session.baseContext.generation,
                message: message,
                normalizedOutput: correctedText
            )
            return false
        }

        recordAcceptedWords(from: correctedText)
        cancelPredictionWork()
        latestGenerationNumber = session.baseContext.generation
        clearSuggestion(clearDiagnostics: false)
        hideOverlay(reason: "Overlay hidden because \(keyName) accepted a typo correction.")
        latestAcceptanceAction = "Accepted typo correction with \(keyName)."
        state = .idle
        logStage(
            "\(keyName)-accepted-correction",
            workID: currentWorkID,
            generation: session.baseContext.generation,
            message: "Replaced the user's last word with the corrected version.",
            normalizedOutput: correctedText
        )
        // Re-arm prediction so the next keystroke can produce a fresh continuation now that the typo
        // is gone — the user usually keeps typing right after accepting.
        schedulePrediction()
        return true
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

    // MARK: - Post-Exhaustion Acceptance Window

    /// How long Cotabby keeps owning Tab after a final-chunk accept while it waits for the
    /// continuation to regenerate. This is only a backstop: the window normally ends much sooner —
    /// when the next suggestion shows (overlay visible) or any teardown hides the overlay. It exists
    /// so a regeneration that silently stalls can never trap Tab in the focused field. Sized to
    /// comfortably outlast the host-publish poll ceiling plus a debounce and a typical on-device
    /// generation.
    static let postExhaustionAcceptanceWindowSeconds: TimeInterval = 0.8

    /// Keeps the accept tap owning Tab for a brief window after a final-chunk accept, while the
    /// continuation regenerates asynchronously.
    ///
    /// Accepting the last buffered word hides the overlay synchronously (which routes through
    /// `onStateChange(.hidden)` and turns interception off) and then reschedules generation through
    /// the host-publish poll + debounce + engine round-trip. That leaves a gap with no active session
    /// and no visible overlay. A fast follow-up Tab in that gap used to hit the fail-open preflight
    /// (`shouldConsumeAcceptKeyProvider` keys on overlay visibility) and the `activeSession != nil`
    /// guard, so the accept tap forwarded the original Tab to the host and focus jumped out of the
    /// field. Re-asserting interception here keeps the tail tap installed and owning Tab across the
    /// regen window (its mach port otherwise lingers only ~50ms), and `shouldConsumeAcceptKeyProvider`
    /// also consults `isPostExhaustionAcceptanceArmed` so the key is still routed in while the overlay
    /// is hidden. A token-keyed backstop guarantees the window can never trap Tab.
    func armPostExhaustionAcceptance() {
        isPostExhaustionAcceptanceArmed = true
        hasQueuedPostExhaustionAccept = false
        inputMonitor.setAcceptInterceptionActive(true)
        postExhaustionAcceptanceGeneration &+= 1
        let generation = postExhaustionAcceptanceGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.postExhaustionAcceptanceWindowSeconds
        ) { [weak self] in
            // Only the generation that scheduled this timer may act on it; a newer accept (or an
            // already-released window) bumped the token, so this fires as a no-op.
            guard let self, self.postExhaustionAcceptanceGeneration == generation else { return }
            self.releasePostExhaustionAcceptanceWindow()
        }
    }

    /// Clears the window flags and invalidates the backstop token, so a timer still pending from
    /// `armPostExhaustionAcceptance` fires as a no-op once the window has ended. Interception is left
    /// to the caller: whether Tab ownership should drop depends on why the window ended (a fresh
    /// suggestion keeps owning it; a teardown or the backstop drops it).
    func clearPostExhaustionAcceptanceWindow() {
        isPostExhaustionAcceptanceArmed = false
        hasQueuedPostExhaustionAccept = false
        // Cancel any pending backstop, which is keyed to the generation captured at arm time.
        postExhaustionAcceptanceGeneration &+= 1
    }

    /// Ends the post-exhaustion window and returns the accept key to the host unless a suggestion is
    /// now visible (in which case the normal overlay path keeps owning it). Idempotent. This is the
    /// backstop release; the common, prompt release is `onStateChange(.hidden)` ending the window as
    /// soon as any teardown hides the overlay.
    func releasePostExhaustionAcceptanceWindow() {
        guard isPostExhaustionAcceptanceArmed || hasQueuedPostExhaustionAccept else { return }
        if !overlayState.isVisible {
            inputMonitor.setAcceptInterceptionActive(false)
        }
        clearPostExhaustionAcceptanceWindow()
    }

    /// Once a regenerated continuation is on screen, accepts its first word if the user pressed Tab
    /// while it was still loading. Keeps rapid Tabbing inserting words across the exhaustion boundary
    /// instead of stalling. Bounded to one queued accept so mashing Tab cannot run away. Called at the
    /// end of `apply`'s success path, after the new session and overlay exist.
    func flushQueuedPostExhaustionAcceptIfNeeded() {
        let shouldAccept = isPostExhaustionAcceptanceArmed && hasQueuedPostExhaustionAccept
        // Normal acceptance has resumed now that a fresh suggestion is visible, so end the window
        // regardless of whether a press was queued (this also cancels the now-redundant backstop).
        clearPostExhaustionAcceptanceWindow()
        guard shouldAccept else { return }
        // A queued accept can still legitimately fail (the new continuation no longer reconciles with
        // live AX, or insertion fails). `acceptSuggestion` cleans up its own state on failure, so log
        // the rare miss for diagnosis instead of letting the swallowed Tab vanish without a trace.
        if !acceptCurrentSuggestion() {
            logStage(
                "flush-queued-accept-failed",
                workID: currentWorkID,
                generation: latestGenerationNumber,
                message: "Flushed a queued post-exhaustion Tab, but the follow-up acceptance returned false."
            )
        }
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
                awaitHostPublish: true,
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
        awaitHostPublish: Bool = false,
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
            // Callers reacting to a *synthetic-tap* keystroke (the user typing through a suggestion)
            // must wait for the host to publish the keystroke before regenerating, or the new
            // suggestion is built against pre-keystroke text in Chromium editors and looks like the
            // typed characters were ignored. Reconcile-path callers, where AX has already settled,
            // schedule immediately.
            if awaitHostPublish {
                schedulePredictionAfterHostPublishDelay()
            } else {
                schedulePrediction()
            }
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
        isRightToLeft: Bool = false,
        isCorrection: Bool = false
    ) {
        let geometry = SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: context.inputFrameRect,
            caretQuality: context.caretQuality,
            observedCharWidth: context.observedCharWidth,
            isRightToLeft: isRightToLeft,
            focusChangeSequence: context.focusChangeSequence,
            focusedInputIdentityKey: context.focusedInputIdentityKey,
            isCorrection: isCorrection,
            resolvedFieldStyle: context.resolvedFieldStyle
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
