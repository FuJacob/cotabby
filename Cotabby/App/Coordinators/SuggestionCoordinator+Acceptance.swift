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

        let insertionText = insertionTextApplyingAutoSpace(
            insertionChunk: insertionChunk,
            acceptedChunk: acceptedChunk,
            session: sessionForAcceptance
        )

        // An empty chunk means the accepted span was entirely a boundary space the field already
        // supplies: advance the session without synthesizing a keystroke.
        if !insertionText.isEmpty, !suggestionInserter.insert(insertionText) {
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
                normalizedOutput: insertionText
            )
            return false
        }

        deferAcceptanceBookkeeping { [weak self] in
            self?.recordAcceptedWords(from: acceptedChunk)
        }

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
            let workID = currentWorkID
            deferAcceptanceBookkeeping { [weak self] in
                self?.logStage(
                    "\(keyName)-accepted-final-chunk",
                    workID: workID,
                    generation: liveContext.generation,
                    message: "Inserted the final suggestion chunk and queued a refresh.",
                    normalizedOutput: acceptedChunk
                )
            }
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
            state = .ready(text: advancedSession.remainingText, latency: advancedSession.latency)
            // The overlay slide stays synchronous on purpose: acceptance validation compares the
            // visible overlay text against the session tail, so a deferred slide could make a
            // rapid follow-up Tab read a stale overlay and pass through to the host.
            presentAdvancedOverlay(
                remainingText: advancedSession.remainingText,
                insertionChunk: insertionChunk,
                liveContext: liveContext
            )
            schedulePostInsertionRefresh()
            let workID = currentWorkID
            deferAcceptanceBookkeeping { [weak self] in
                self?.applySessionDiagnostics(
                    advancedSession,
                    acceptanceAction: "Accepted next chunk with \(keyName)."
                )
                self?.logStage(
                    "\(keyName)-accepted-chunk",
                    workID: workID,
                    generation: liveContext.generation,
                    message: "Inserted the next suggestion chunk and kept the remaining tail active.",
                    normalizedOutput: acceptedChunk
                )
            }
            return true
        }
    }

    /// Applies the opt-in "add a space after accepting" setting to the text about to be inserted.
    ///
    /// The trailing space is only appended when this accept *exhausts* the suggestion — predicted the
    /// same way `commitAcceptedChunk` decides it — because a mid-suggestion word accept is already
    /// followed by the next chunk's own leading space, so a space here would double up. Only the
    /// inserted text grows: session accounting still advances by the unchanged `acceptedChunk`, and
    /// the session tears down on exhaustion, so the extra space never disturbs the consumed-suffix
    /// reconciliation a still-live session relies on. Whether the space actually lands (vs. being
    /// suppressed after punctuation, whitespace, or a space-less script) is the reconciler's rule.
    private func insertionTextApplyingAutoSpace(
        insertionChunk: String,
        acceptedChunk: String,
        session: ActiveSuggestionSession
    ) -> String {
        guard settingsSnapshot.addSpaceAfterAccept,
              session.advancing(by: acceptedChunk.count).isExhausted else {
            return insertionChunk
        }
        return SuggestionSessionReconciler.insertionChunkAppendingTrailingSpace(insertionChunk)
    }

    /// Runs acceptance bookkeeping one runloop hop after the consuming tap callback returns.
    ///
    /// While ghost text is visible the accept tap gates every keyDown system-wide, and the whole
    /// acceptance executes inside that callback before the original key is released. Work that
    /// neither decides consumption nor upholds the overlay/session invariant (counter persistence,
    /// stage logging, diagnostics publishes) does not belong on that synchronous path; a
    /// `UserDefaults` write in particular can stall on the preferences daemon at the worst moment.
    /// Captured values keep the deferred log lines describing the accept that scheduled them.
    private func deferAcceptanceBookkeeping(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            work()
        }
    }

    /// Repositions the overlay after a word accept. Prefers sliding the existing ghost by the exact
    /// rendered width of the accepted text so the remaining tail stays perfectly still (no
    /// predicted-vs-AX two-step). Falls back to a caret-anchored present only when the overlay cannot
    /// be slid (mirror mode, RTL, multi-line, or nothing rendered yet).
    private func presentAdvancedOverlay(
        remainingText: String,
        insertionChunk: String,
        liveContext: FocusedInputContext
    ) {
        if overlayController.advanceInline(to: remainingText, insertedText: insertionChunk) {
            return
        }

        let isRTL = TextDirectionDetector.isRightToLeft(liveContext.precedingText)
        let predictedCaret = Self.predictedCaretRect(
            after: insertionChunk,
            oldCaretRect: liveContext.caretRect,
            caretQuality: liveContext.caretQuality,
            observedCharWidth: liveContext.observedCharWidth,
            fieldStyle: liveContext.resolvedFieldStyle,
            isRightToLeft: isRTL
        )
        presentOverlay(
            text: remainingText,
            at: predictedCaret,
            context: liveContext,
            isRightToLeft: isRTL,
            // The host has not published the synthetic insert yet, so the live prefix is
            // pre-insertion; the layout repair needs the chunk to anchor after the inserted text.
            pendingInsertion: insertionChunk
        )
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
        // Confirm the live field still ends with the exact word we offered to correct (tolerating
        // one trailing space the user pressed after it). Comparing the word itself, not just its
        // length, closes the window where a keystroke between the last AX poll and this Tab swapped
        // in a different same-length word; if it diverged, pass the key through rather than delete
        // the wrong text.
        guard case let .correction(typoWord) = session.kind,
              let replacement = TypoCorrectionReplacementPlanner.plan(
                  precedingText: rawContext.precedingText,
                  expectedTypo: typoWord,
                  correctedWord: session.fullText,
                  requiresTrailingSpace: false
              ) else {
            return passTabThrough(reason: "Key passed through because the word to correct changed.")
        }

        guard suggestionInserter.replace(
            deletingUTF16Count: replacement.deletingUTF16Count,
            with: replacement.replacementText
        ) else {
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
                normalizedOutput: replacement.replacementText
            )
            return false
        }

        cancelPredictionWork()
        latestGenerationNumber = session.baseContext.generation
        clearSuggestion(clearDiagnostics: false)
        hideOverlay(reason: "Overlay hidden because \(keyName) accepted a typo correction.")
        state = .idle
        let workID = currentWorkID
        deferAcceptanceBookkeeping { [weak self] in
            self?.recordAcceptedWords(from: replacement.replacementText)
            self?.latestAcceptanceAction = "Accepted typo correction with \(keyName)."
            self?.logStage(
                "\(keyName)-accepted-correction",
                workID: workID,
                generation: session.baseContext.generation,
                message: "Replaced the user's last word with the corrected version.",
                normalizedOutput: replacement.replacementText
            )
        }
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
        let workID = currentWorkID
        deferAcceptanceBookkeeping { [weak self] in
            self?.logStage(
                "tab-passed-through",
                workID: workID,
                generation: generation,
                message: reason
            )
        }
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
        // Same slide as Tab acceptance; the user typed the next characters, so the caret traveled
        // by exactly them. Fall back to the (session-start) caret anchor only if the slide can't apply.
        if !overlayController.advanceInline(to: advancedSession.remainingText, insertedText: typedCharacters) {
            presentOverlay(
                text: advancedSession.remainingText,
                at: session.baseContext.caretRect,
                context: session.baseContext
            )
        }
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
    /// directly — this matches the target app's actual font. Otherwise the field's resolved font
    /// measures the chunk (the host's true caret travel), and only a host with no usable style
    /// falls back to a system-font approximation.
    static func predictedCaretRect(
        after insertedChunk: String,
        oldCaretRect: CGRect,
        caretQuality: CaretGeometryQuality,
        observedCharWidth: CGFloat?,
        fieldStyle: ResolvedFieldStyle? = nil,
        isRightToLeft: Bool = false
    ) -> CGRect {
        let measuredWidth = predictedChunkWidth(
            insertedChunk: insertedChunk,
            observedCharWidth: observedCharWidth,
            fieldStyle: fieldStyle
        )
        let chunkWidth: CGFloat

        switch caretQuality {
        case .exact, .derived, .layoutEstimated:
            // `.layoutEstimated` is unreachable here in practice — prediction always receives the
            // context's raw resolver quality, and the layout repair only upgrades the overlay
            // geometry, never the context. Folded into the trusted arm to keep the switch
            // exhaustive with the semantics it would want anyway.
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
        observedCharWidth: CGFloat?,
        fieldStyle: ResolvedFieldStyle? = nil
    ) -> CGFloat {
        if let observed = observedCharWidth {
            return observed * CGFloat(insertedChunk.count)
        }

        // The field's own font is the host's true caret travel; the system-14 fallback measured
        // TextEdit's Helvetica 12 a quarter too wide, and the resulting overshoot surfaced as a
        // corrective snap once AX published the real caret.
        if let hostAdvance = InsertedTextAdvance.width(of: insertedChunk, style: fieldStyle) {
            return hostAdvance
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14)
        ]
        return (insertedChunk as NSString).size(withAttributes: attrs).width
    }

    /// Gives the host app ~30ms to process the synthetic keystroke, then forces an AX snapshot
    /// so the overlay snaps to the real caret position without waiting for the 80ms poll.
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
        isCorrection: Bool = false,
        pendingInsertion: String = ""
    ) {
        let anchor = Self.layoutRepairedAnchor(
            for: context,
            fallbackRect: caretRect,
            pendingInsertion: pendingInsertion,
            isRightToLeft: isRightToLeft
        )
        logCaretLayoutRepair(anchor: anchor, fallbackRect: caretRect, context: context)
        let geometry = SuggestionOverlayGeometry(
            caretRect: anchor.rect,
            inputFrameRect: context.inputFrameRect,
            caretQuality: anchor.quality,
            isCaretAtEndOfLine: context.isCaretAtEndOfLine,
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

    /// Repairs untrustworthy caret anchors with a hidden-text-layout estimate before presentation.
    ///
    /// The repair's authority is scoped by where the AX geometry came from, not just its quality:
    ///   - `.estimated` (AXFrame-only hosts): the AX guess has no real position at all, so a
    ///     passing estimate always replaces it. Applies to web and native hosts alike, because
    ///     there is no real measurement to protect.
    ///   - `.derived` in a native host: never repaired, the estimator does not run. Native AX
    ///     per-character bounds come from the app's real layout manager and reflect rendering the
    ///     uniform hidden layout cannot model (Notes renders a 23pt title line above 16pt body
    ///     lines, plus paragraph spacing, so the layout "disagrees" within a few lines while AX is
    ///     exactly right). A vertical mismatch there indicts the estimate, not AX.
    ///   - `.derived` with measured run frames (Gmail/Outlook child-run hosts): the rect's Y is a
    ///     real rendered line, so it is always kept and the estimator does not run at all; the
    ///     layout estimate cannot beat measurement (and is blind to blank lines those hosts
    ///     collapse out of the AX text).
    ///   - `.derived` web content without run frames (previous-character bounds through a web
    ///     engine's AX bridge, which has known wrong-line pathologies): the estimate (calibrated
    ///     with whatever the host revealed) only overrides the AX rect when the two disagree
    ///     vertically by more than `verticallyAgrees` tolerates; on agreement the AX rect is kept.
    ///
    /// On substitution the overlay geometry is upgraded to `.layoutEstimated`, which the render
    /// policy trusts for inline ghost text; on rejection the passed rect and quality survive
    /// untouched. The context itself is never mutated — resolver truth stays intact for
    /// reconciliation and caret prediction.
    ///
    /// `pendingInsertion` exists for the word-accept path: the synthetic insert has not been
    /// published back through AX yet, so `context.precedingText` is pre-insertion while the caret
    /// belongs after the inserted chunk. Appending the chunk lets the layout place the caret where
    /// the text actually is, including a wrap onto the next line that a pure X-shift cannot model.
    ///
    /// Static (like `predictedCaretRect`) so tests can exercise the substitution rule directly.
    static func layoutRepairedAnchor(
        for context: FocusedInputContext,
        fallbackRect: CGRect,
        pendingInsertion: String,
        isRightToLeft: Bool
    ) -> LayoutRepairedAnchor {
        let quality = context.caretQuality
        guard quality == .estimated || quality == .derived else {
            return LayoutRepairedAnchor(rect: fallbackRect, quality: quality, outcome: nil, skipReason: nil)
        }

        // Derived rects carry a real AX measurement, so whether the estimate may second-guess
        // them depends on who produced the measurement. Both bypasses skip the estimator
        // entirely rather than computing a diagnostic they can never act on: this path runs
        // inside the accept keystroke's handling window, where every spent millisecond of layout
        // work on a large flat prefix is pure risk during a rapid Tab burst.
        if quality == .derived {
            // Native hosts: per-character bounds come from the app's own layout manager and are
            // ground truth, while the uniform hidden layout cannot model rich text (Notes' taller
            // title line and paragraph spacing put it a line off within a few paragraphs). Only
            // web engines' AX bridges have the wrong-line pathologies the override exists for.
            if !context.isWebContentField {
                return LayoutRepairedAnchor(
                    rect: fallbackRect, quality: .derived, outcome: nil, skipReason: .nativeHostGeometry
                )
            }
            // Run-measured derived rects are kept unconditionally: run frames carry the host's
            // real line positions, including blank lines some hosts omit from the AX text.
            if context.observedContentEdges != nil {
                return LayoutRepairedAnchor(
                    rect: fallbackRect, quality: .derived, outcome: nil, skipReason: .runMeasuredGeometry
                )
            }
        }

        // A `.derived` rect's height is a real rendered line box (previous-character bounds); the
        // `.estimated` AXFrame fallback's height is the whole field, which the estimator's
        // sanitizer would discard anyway — pass it for derived geometry only.
        let observedLineHeight: CGFloat? = quality == .derived ? context.caretRect.height : nil

        // Truncation is checked against the captured window, not the appended insertion: only the
        // snapshot capture can silently drop the document start.
        let input = TextLayoutCaretEstimator.Input(
            precedingText: context.precedingText + pendingInsertion,
            fieldFrame: context.inputFrameRect,
            fieldStyle: context.resolvedFieldStyle,
            isRightToLeft: isRightToLeft,
            prefixMayBeTruncated:
                context.precedingText.utf16.count >= FocusSnapshotResolver.focusedTextContextWindowUTF16,
            observedLineHeight: observedLineHeight,
            observedCharWidth: context.observedCharWidth,
            observedContentEdges: context.observedContentEdges
        )
        let outcome = TextLayoutCaretEstimator.estimate(for: input)
        switch outcome {
        case .estimate(let estimate):
            if quality == .derived, verticallyAgrees(estimate: estimate, axRect: fallbackRect) {
                // Same line: keep the AX rect, whose X carries the host's real glyph positions.
                return LayoutRepairedAnchor(rect: fallbackRect, quality: .derived, outcome: outcome, skipReason: nil)
            }
            return LayoutRepairedAnchor(
                rect: estimate.caretRect, quality: .layoutEstimated, outcome: outcome, skipReason: nil
            )
        case .rejected:
            return LayoutRepairedAnchor(rect: fallbackRect, quality: quality, outcome: outcome, skipReason: nil)
        }
    }

    /// Vertical agreement test between the AX-derived caret and the layout estimate. Tolerance is
    /// three-quarters of a line: same-line measurements differ by baseline and padding subtleties,
    /// while the failure this repairs (the caret mapped into a neighboring visual line) is off by
    /// at least one full line box.
    private static func verticallyAgrees(
        estimate: TextLayoutCaretEstimator.Estimate,
        axRect: CGRect
    ) -> Bool {
        let tolerance = max(10, estimate.caretRect.height * 0.75)
        return abs(estimate.caretRect.midY - axRect.midY) <= tolerance
    }

    /// What one layout-repair attempt decided the overlay geometry should anchor to, plus the
    /// estimator outcome for structured logging (nil when repair did not apply at all).
    struct LayoutRepairedAnchor {
        let rect: CGRect
        let quality: CaretGeometryQuality
        let outcome: TextLayoutCaretEstimator.Outcome?
        /// Why a derived rect bypassed the estimator without running it (nil when the estimator
        /// ran, or when repair was out of scope for the quality entirely). Logged so "the caret
        /// came from trusted AX and repair stood down" is distinguishable from "this field never
        /// triggered repair" when diagnosing a misplaced overlay from the JSONL stream.
        let skipReason: LayoutRepairSkipReason?
    }

    /// Why `layoutRepairedAnchor` kept a derived AX rect without running the estimator at all.
    /// Raw values feed the structured log stream.
    enum LayoutRepairSkipReason: String {
        /// Native (non-web) host: AX-derived geometry is ground truth for the trust policy.
        case nativeHostGeometry = "native_host_geometry"
        /// The rect was measured from child text-run frames, which outrank any estimate.
        case runMeasuredGeometry = "run_measured_geometry"
    }

    /// Mirrors the repair outcome into the structured JSONL stream so a misplaced overlay can be
    /// joined to the exact gate decision via `request_id`. The metadata deliberately carries the
    /// estimate-vs-AX vertical delta and which host measurements calibrated the layout, because
    /// field reports of "ghost is N lines off" are only diagnosable from those numbers.
    /// Deliberately not routed through `logStage`: that helper also mutates the UI-facing
    /// `latestStageMessage`, and a per-present geometry detail should not overwrite the
    /// user-visible pipeline stage.
    private func logCaretLayoutRepair(
        anchor: LayoutRepairedAnchor,
        fallbackRect: CGRect,
        context: FocusedInputContext
    ) {
        // Exact/layout-estimated presentations never reach repair and carry nothing to log; bail
        // before building metadata so the common path pays nothing per present.
        guard anchor.outcome != nil || anchor.skipReason != nil else {
            return
        }
        var metadata: Logger.Metadata = [
            "stage": .string("caret-layout-repair"),
            "work_id": .stringConvertible(currentWorkID),
            "request_id": .string(latestRequestID ?? "req_none"),
            "caret_source": .string(context.caretSource),
            // Absolute geometry of the anchor that will actually be shown, so field reports can be
            // checked numerically against a known page layout instead of eyeballing screenshots.
            "anchor_x": .stringConvertible(Double(anchor.rect.midX)),
            "anchor_mid_y": .stringConvertible(Double(anchor.rect.midY))
        ]
        if let fieldFrame = context.inputFrameRect {
            metadata["field_top_y"] = .stringConvertible(Double(fieldFrame.maxY))
        }
        guard let outcome = anchor.outcome else {
            // A trusted-AX bypass stood the estimator down without running it. Logged (unlike the
            // qualities repair never applies to) so the stream can distinguish "repair deferred to
            // trusted AX" from "this presentation never reached repair".
            if let skipReason = anchor.skipReason {
                metadata["repair_outcome"] = .string("skipped")
                metadata["skip_reason"] = .string(skipReason.rawValue)
                CotabbyLogger.suggestion.debug(
                    "Kept the AX caret; its geometry source outranks the layout estimate.",
                    metadata: metadata
                )
            }
            return
        }
        switch outcome {
        case .estimate(let estimate):
            let substituted = anchor.quality == .layoutEstimated
            metadata["repair_outcome"] = .string(substituted ? "substituted" : "kept_ax_agreement")
            metadata["line_index"] = .stringConvertible(estimate.lineIndex)
            metadata["multi_line_field"] = .stringConvertible(estimate.isMultiLineField)
            metadata["ax_mid_y_delta"] = .stringConvertible(
                Double(estimate.caretRect.midY - fallbackRect.midY))
            metadata["line_height"] = .stringConvertible(Double(estimate.lineHeight))
            metadata["used_observed_line_height"] = .stringConvertible(estimate.usedObservedLineHeight)
            metadata["used_observed_content_edges"] = .stringConvertible(estimate.usedObservedContentEdges)
            metadata["layout_font_point_size"] = .stringConvertible(Double(estimate.layoutFontPointSize))
            CotabbyLogger.suggestion.debug(
                substituted
                    ? "Replaced the AX caret with a text-layout estimate."
                    : "Kept the AX caret over the text-layout estimate.",
                metadata: metadata
            )
        case .rejected(let reason):
            metadata["repair_outcome"] = .string("rejected")
            metadata["reject_reason"] = .string(reason.rawValue)
            CotabbyLogger.suggestion.debug(
                "Kept the AX caret; the text-layout estimate was rejected.",
                metadata: metadata
            )
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
        // Repeated keystrokes produce identical stage messages; republishing the same string
        // would still fire `objectWillChange` and re-render every coordinator observer.
        if latestStageMessage != message {
            latestStageMessage = message
        }
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
        // Level-gate before building the metadata dictionary: stages fire per keystroke, and at
        // the default `.info` floor the line is dropped anyway, so the allocations would be waste.
        guard CotabbyLogger.suggestion.logLevel <= .debug else {
            return
        }

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
