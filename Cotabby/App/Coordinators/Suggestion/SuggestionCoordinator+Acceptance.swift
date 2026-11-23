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

    /// Entry point for a real press of the Accept Word key.
    ///
    /// With double-tap enabled, the first press still accepts one word immediately, and a second
    /// press within `DoubleTapAcceptanceState.window` on the same suggestion accepts what remains.
    /// Promoting the second press instead of delaying the first keeps single-word acceptance as fast
    /// as before; the pair still commits the whole suggestion. A press held during post-exhaustion
    /// regeneration is never replayed at all (see `endPostExhaustionWindowForFreshSuggestion`), so
    /// it can neither accept nor double-tap a continuation the user has not seen yet.
    ///
    /// `isAutorepeat` marks a key-down the system generated because the key is held. Those keep
    /// accepting word by word, as holding the key always has, but a held key is one long press:
    /// a repeat neither completes a pending double tap nor arms a new one. Without this, holding
    /// Accept Word past the first repeat (repeats arrive well inside the window) took everything.
    ///
    /// The focused app is resolved from the same focus snapshot the input monitor used to classify
    /// this press, so an app with its own Accept Entire Suggestion binding keeps it here too.
    ///
    /// `isPlainTab` marks a press of Tab without modifiers. With `tabLeavesSingleLineFields` on, such
    /// a press in a single-line field is handed back to the host instead of accepting, so Tab moves
    /// to the next form field as it would without Cotabby. While a double tap of the same key
    /// accepts the whole suggestion, the press keeps accepting instead: handing the first Tab to the
    /// host would leave no second press, and so no way at all to accept everything in that field.
    func acceptForWordAcceptKeyPress(isAutorepeat: Bool, isPlainTab: Bool = false) -> Bool {
        let doubleTapApplies = settingsSnapshot.isDoubleTapFullAcceptanceActive(
            forBundleIdentifier: focusModel.snapshot.bundleIdentifier
        )
        if isPlainTab, !doubleTapApplies, settingsSnapshot.tabLeavesSingleLineFields, tabMovesFocusInFocusedField {
            doubleTapAcceptanceState.reset()
            return passTabThrough(reason: "Tab left to the host in a single-line field")
        }

        guard doubleTapApplies, !isAutorepeat else {
            doubleTapAcceptanceState.reset()
            return acceptCurrentSuggestion()
        }

        let now = doubleTapUptimeProvider()
        if let session = interactionState.activeSession, !session.kind.isCorrection,
           doubleTapAcceptanceState.consumeDoubleTap(of: .init(session: session), at: now) {
            return acceptSuggestion(fullText: true, keyName: "double-tap")
        }

        let accepted = acceptCurrentSuggestion()
        // Arm only when this press left a continuation with text still to accept. An exhausted
        // suggestion hands Tab to the post-exhaustion window instead, and a correction commits as
        // a unit, so neither has a "rest" for a second press to take.
        if accepted, let advanced = interactionState.activeSession, !advanced.kind.isCorrection,
           !advanced.isExhausted {
            doubleTapAcceptanceState.recordWordAccept(of: .init(session: advanced), at: now)
        } else {
            doubleTapAcceptanceState.reset()
        }
        return accepted
    }

    /// Shared acceptance path used by both word-by-word and full acceptance.
    private func acceptSuggestion(
        fullText: Bool,
        keyName: String
    ) -> Bool {
        // A tab switch can precede the next timer poll. Refresh before committing text, while
        // preserving the short reuse window for rapid consecutive accepts in the same field.
        focusModel.refreshIfStale(maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
        let snapshot = focusModel.snapshot

        // The disabled reason already covers every top-level gate (off, paused, disabled app or
        // site, missing Input Monitoring, an unsupported field), so only the context is left.
        if let disabledReason = currentDisabledReason(focusSnapshot: snapshot) {
            return passTabThrough(reason: disabledReason)
        }

        guard let rawContext = snapshot.context else {
            return passTabThrough(reason: snapshot.capability.summary)
        }

        // Enforce visual-context expiry even if its timer was delayed by a busy main run loop.
        // The invalidation callback retires any visible suggestion based on that old excerpt.
        _ = visualContextCoordinator.excerpt(for: FocusedInputContext(snapshot: rawContext, generation: 0))

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
        // A presentation the overlay is still holding (pixel caret read, lagging host caret) leaves
        // `overlayState` naming the pre-accept tail for a few tens of milliseconds. Hand the held
        // text to validation so a rapid second Tab accepts the tail Cotabby is about to paint
        // instead of mismatching, tearing the session down, and leaking Tab into the host.
        let heldPresentationText = overlayController.heldPresentationText
        // The ghost on a host that offers one row paints only the head that fits; one press may
        // insert only that head, never the unseen rest the session still holds.
        let truncatedDisplayText = overlayController.truncatedDisplayText
        let preparation: SuggestionAcceptancePreparation
        if fullText {
            preparation = interactionState.prepareFullAcceptance(
                from: rawContext,
                overlayState: overlayState,
                heldPresentationText: heldPresentationText,
                truncatedDisplayText: truncatedDisplayText
            )
        } else {
            preparation = interactionState.prepareAcceptance(
                from: rawContext,
                overlayState: overlayState,
                heldPresentationText: heldPresentationText,
                truncatedDisplayText: truncatedDisplayText,
                granularity: primaryGranularity,
                autoAcceptTrailingPunctuation: settingsSnapshot.autoAcceptTrailingPunctuation
            )
        }

        return commitPreparedAcceptance(preparation, rawContext: rawContext, keyName: keyName)
    }

    /// Preparation validates the live session; this stage performs insertion and advances that
    /// exact session. Keeping the handoff explicit avoids repeating eligibility checks mid-commit.
    private func commitPreparedAcceptance(
        _ preparation: SuggestionAcceptancePreparation,
        rawContext: FocusedInputSnapshot,
        keyName: String
    ) -> Bool {
        let liveContext: FocusedInputContext
        let sessionForAcceptance: ActiveSuggestionSession
        let acceptedChunk: String
        switch preparation {
        case let .ready(preparedLiveContext, preparedSession, preparedAcceptedChunk):
            liveContext = preparedLiveContext
            sessionForAcceptance = preparedSession
            // With "add space after accepting" on, a word-ending accept also takes the suggestion's
            // own following space so the trailing space lands now instead of with the next accept.
            // This is what makes the setting fire on every word, not only the final one that
            // exhausts the suggestion (which `insertionTextApplyingAutoSpace` still covers).
            acceptedChunk = autoSpaceAdjustedChunk(preparedAcceptedChunk, session: preparedSession)

        case let .invalid(reason):
            return passTabThrough(reason: reason)

        case let .unshown(reason):
            // Own the key and insert nothing: the text this press would take is not on screen yet,
            // and the session stays so the present that shows it can land. Passing the key through
            // instead would tear down a live suggestion and move focus out of the field.
            let workID = currentWorkID
            let generation = latestGenerationNumber
            deferAcceptanceBookkeeping { [weak self] in
                self?.logStage("\(keyName)-held-unshown", workID: workID, generation: generation, message: reason)
            }
            return true
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
            retireSuggestion(reason: "Overlay hidden because suggestion insertion failed.", clearDiagnostics: true)
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
            self?.recordSuggestionAcceptedIfFirstChunk(of: sessionForAcceptance)
        }

        // The insert just made every geometry cache built from pre-insert reads stale: child-run
        // hosts would otherwise map the published caret into pre-insert run frames for up to a
        // throttle window. Stamp the acceptance so the stability gate can scope its
        // backward-drift hold to the frames-catching-up window.
        lastAcceptanceAt = ProcessInfo.processInfo.systemUptime
        focusModel.invalidateTransientCaretCaches()

        if preparedContinuation == nil, sessionForAcceptance.advancing(by: acceptedChunk.count).isExhausted {
            prepareContinuation(after: sessionForAcceptance, rawContext: rawContext)
        }
        cancelPredictionWork(preservingContinuation: true)

        switch interactionState.commitAcceptedChunk(acceptedChunk, session: sessionForAcceptance) {
        case .exhausted:
            let hasPreparedContinuation = markPreparedContinuationCommitted(after: sessionForAcceptance)
            latestGenerationNumber = liveContext.generation
            retireSuggestion(
                reason: "Overlay hidden because \(keyName) accepted the final suggestion chunk.",
                preservingContinuation: hasPreparedContinuation
            )
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
            // swallowed instead of leaking into the host app as a real Tab. Must run
            // *after* the `hideOverlay` above, which routes through `onStateChange(.hidden)` and
            // turns interception off; arming re-asserts it. See `armPostExhaustionAcceptance`.
            let expected = SpeculativeAcceptanceContext.optimisticSnapshot(
                after: rawContext, inserting: insertionText
            )
            if SuggestionRequestFactory.shouldGenerateSuggestion(
                for: expected.precedingText, suggestWithinWords: settingsSnapshot.suggestWithinWords
            ) {
                armPostExhaustionAcceptance()
            }
            // Start the continuation against the text the host is about to publish instead of
            // idling through the publish poll first; the poll below validates the bet (see
            // dispatchSpeculativePostAcceptanceGeneration).
            if !hasPreparedContinuation {
                dispatchSpeculativePostAcceptanceGeneration(rawContext: rawContext, insertionChunk: insertionText)
            }
            // Wait for the host to actually publish the inserted text before regenerating. A bare
            // `schedulePrediction()` here reads pre-insertion AX in Chromium editors (the publish lags
            // the synthetic keystroke), so the model re-proposes the word just accepted and the next
            // accept re-inserts it. That is the final-word accept/regenerate/accept loop reported as
            // the suggestion "flickering" without committing. Polling until the insert surfaces (the
            // same path typing uses) makes the regeneration read the settled text and return a genuine
            // next suggestion, or nothing.
            schedulePredictionAfterHostPublishDelay()
            return true

        case let .advanced(advancedSession):
            latestGenerationNumber = liveContext.generation
            state = .ready
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

    /// Applies the opt-in "add a space after accepting" setting to the chunk being accepted, by
    /// extending a word-ending chunk to also take the suggestion's own following space. The whole
    /// flow (insertion text, session advance, overlay) then runs on the extended chunk, so the space
    /// is consumed from the buffered suggestion rather than synthesized: the session stays in
    /// lockstep with the field and the reconciler's existing rule drops the next chunk's now-leading
    /// space, so there is no double space. See `acceptanceChunkConsumingTrailingSpace`.
    private func autoSpaceAdjustedChunk(_ chunk: String, session: ActiveSuggestionSession) -> String {
        guard settingsSnapshot.addSpaceAfterAccept else {
            return chunk
        }
        return SuggestionSessionReconciler.acceptanceChunkConsumingTrailingSpace(
            chunk,
            remainingText: session.predictedRemainingText
        )
    }

    /// Appends the trailing space for the *final* accept of a suggestion — the one case
    /// `autoSpaceAdjustedChunk` cannot cover, because an exhausting accept has no following
    /// suggestion whitespace to consume. Fires only when this accept exhausts the suggestion
    /// (predicted the same way `commitAcceptedChunk` decides it). Here the inserted text grows by a
    /// synthesized space, but the session tears down on exhaustion, so it never disturbs the
    /// consumed-suffix reconciliation a still-live session relies on. Whether the space actually
    /// lands (vs. being suppressed after punctuation, whitespace, or a space-less script) is the
    /// reconciler's rule.
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
        // A layout-estimated anchor lives in the hidden text layout's coordinate system, and the
        // estimator models the accepted chunk's true advance (soft wrap included) better than any
        // width shift can: that re-anchor, fed with the pending insertion below, is exactly what
        // the caret repair was built for on these hosts. Sliding instead leaves the anchor a
        // ghost-vs-host font error away from the next estimate and the settle showed up as a
        // post-accept jerk. Skip the slide so the estimator places the tail where the
        // post-publish estimate will also land; nothing moves afterwards.
        let heldOverlayQuality: CaretGeometryQuality?
        if case let .visible(_, geometry, _) = overlayState {
            heldOverlayQuality = geometry.caretQuality
        } else {
            heldOverlayQuality = nil
        }
        if heldOverlayQuality != .layoutEstimated,
           overlayController.advanceInline(to: remainingText, insertedText: insertionChunk) {
            recordSuggestionPresentation(context: liveContext)
            return
        }

        let isRTL = TextDirectionDetector.isRightToLeft(liveContext.precedingText)
        let predictedCaret = PredictedCaretAdvance.caretRect(
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
    /// regeneration window we keep owning the key and swallow the press; otherwise the key passes
    /// through to the host.
    private func handleAcceptWithoutActiveSession(keyName: String) -> Bool {
        // A final-chunk accept tears the session down and regenerates the continuation
        // asynchronously (see the `.exhausted` branch). While that regen is in flight we keep owning
        // Tab instead of leaking it into the host app as a real Tab. The press is not saved up for
        // the continuation: it was made before that text existed, so it cannot be a decision to
        // accept it.
        if postExhaustionAcceptanceState.holdPressIfArmed() {
            logStage(
                "\(keyName)-held-for-regen",
                workID: currentWorkID,
                generation: latestGenerationNumber,
                message: "Swallowed a rapid \(keyName) during post-acceptance regeneration; "
                    + "the next continuation must be shown before a press can accept it."
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
        guard correctionSessionMatches(session, rawContext: rawContext),
              case let .correction(typoWord) = session.kind,
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
            retireSuggestion(reason: "Overlay hidden because correction insertion failed.", clearDiagnostics: true)
            logStage(
                "correction-insert-failed",
                workID: currentWorkID,
                generation: session.baseContext.generation,
                message: message,
                normalizedOutput: replacement.replacementText
            )
            return false
        }

        lastAcceptanceAt = ProcessInfo.processInfo.systemUptime
        focusModel.invalidateTransientCaretCaches()
        if preparedContinuation == nil { prepareContinuation(after: session, rawContext: rawContext) }
        cancelPredictionWork(preservingContinuation: true)
        let hasPreparedContinuation = markPreparedContinuationCommitted(after: session)
        latestGenerationNumber = session.baseContext.generation
        retireSuggestion(
            reason: "Overlay hidden because \(keyName) accepted a typo correction.",
            preservingContinuation: hasPreparedContinuation
        )
        let workID = currentWorkID
        deferAcceptanceBookkeeping { [weak self] in
            self?.recordAcceptedWords(from: replacement.replacementText)
            self?.logStage(
                "\(keyName)-accepted-correction",
                workID: workID,
                generation: session.baseContext.generation,
                message: "Replaced the user's last word with the corrected version.",
                normalizedOutput: replacement.replacementText
            )
        }
        // Replacement publishes asynchronously through Accessibility, just like accepting a
        // completion. Wait for that edit before predicting, or a fast engine can offer the same
        // correction again. Keep the same bounded Tab handoff used after a final word accept so
        // a second quick Tab can accept the next word instead of moving focus out of the editor.
        armPostExhaustionAcceptance()
        schedulePredictionAfterHostPublishDelay(requiresTextChange: true)
        return true
    }

    /// Whether Tab in the focused field should move focus rather than accept: a field the host lays
    /// out on one line (see `FocusedInputContext.isSingleLineField`), outside chat apps and the named
    /// Electron editors. Both are excluded because their composers can report a single-line role
    /// although Tab has nowhere useful to go there (2026-11-18): Messages' composer is an
    /// `AXTextField`, and Signal's `contenteditable` composer reports one while the message fits on
    /// one line, then a text area once it wraps. Handing them Tab inserted a tab character. The
    /// Claude desktop composer showed the same symptom, Tab sometimes moving focus out of it, which
    /// is why the exclusion covers the named Electron editors rather than chat apps alone, and why
    /// Claude is named here as well: it is not in `BrowserAppDetector`'s editor list on main yet.
    /// WhatsApp's Catalyst composer reports a text area throughout and was unaffected.
    private var tabMovesFocusInFocusedField: Bool {
        guard let raw = focusModel.snapshot.context else { return false }
        let context = interactionState.materializeContext(from: raw)
        guard context.isSingleLineField else { return false }
        let bundleIdentifier = context.bundleIdentifier
        if Self.tabKeepsAcceptingBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }
        if AppSurfaceClassifier.classify(bundleIdentifier: bundleIdentifier) == .chat {
            return false
        }
        return !BrowserAppDetector.isElectronEditor(bundleIdentifier: bundleIdentifier)
    }

    /// Composers that report a single-line role but are not chat apps by `AppSurfaceClassifier` nor
    /// named Electron editors by `BrowserAppDetector`.
    static let tabKeepsAcceptingBundleIdentifiers: Set<String> = [
        "com.anthropic.claudefordesktop"  // Claude desktop: Tab moved focus out of its composer
    ]

    /// Returns control of the accept key to the host app and clears stale suggestion UI.
    ///
    /// `InputMonitor` calls this from the consuming tap before returning a callback result. A `false`
    /// return tells that tap to pass the original key event through naturally, so no synthetic
    /// replay is needed.
    func passTabThrough(reason: String) -> Bool {
        suggestionPresentationTiming.clear()
        let generation = latestGenerationNumber
        cancelPredictionWork()
        retireSuggestion(reason: reason, clearDiagnostics: true)
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
    /// also consults the extracted state so the key is still routed in while the overlay is hidden.
    /// A token-keyed backstop guarantees the window can never trap Tab.
    func armPostExhaustionAcceptance() {
        let generation = postExhaustionAcceptanceState.arm()
        inputMonitor.setAcceptInterceptionActive(true)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.postExhaustionAcceptanceWindowSeconds
        ) { [weak self] in
            // Only the generation that scheduled this timer may act on it; a newer accept (or an
            // already-released window) bumped the token, so this fires as a no-op.
            guard let self,
                  self.postExhaustionAcceptanceState.ownsBackstop(generation: generation) else { return }
            self.releasePostExhaustionAcceptanceWindow()
        }
    }

    /// Clears the window flags and invalidates the backstop token, so a timer still pending from
    /// `armPostExhaustionAcceptance` fires as a no-op once the window has ended. Interception is left
    /// to the caller: whether Tab ownership should drop depends on why the window ended (a fresh
    /// suggestion keeps owning it; a teardown or the backstop drops it).
    func clearPostExhaustionAcceptanceWindow() {
        postExhaustionAcceptanceState.clear()
    }

    /// Ends the post-exhaustion window and returns the accept key to the host unless a suggestion is
    /// now visible (in which case the normal overlay path keeps owning it). Idempotent. This is the
    /// backstop release; the common, prompt release is `onStateChange(.hidden)` ending the window as
    /// soon as any teardown hides the overlay.
    func releasePostExhaustionAcceptanceWindow() {
        guard postExhaustionAcceptanceState.isArmed else { return }
        if !overlayState.isVisible {
            inputMonitor.setAcceptInterceptionActive(false)
        }
        clearPostExhaustionAcceptanceWindow()
    }

    /// Ends the post-exhaustion window once a regenerated continuation has been handed to the
    /// overlay. Called at the end of `presentFreshResult`, after the new session exists.
    ///
    /// A press swallowed during the window is dropped here, not replayed as an accept. It was made
    /// before this continuation existed, and replaying it would insert the continuation's first
    /// word in the same run-loop turn it is first presented, or while the overlay is still holding
    /// it off screen for a caret read: text the user never saw. Delivering the press to the host
    /// late is no better, since a Tab there moves focus out of the field, which is what the window
    /// exists to prevent. The next press, made with the new ghost on screen, accepts as usual.
    /// Ending the window also invalidates the backstop now that normal acceptance has resumed.
    func endPostExhaustionWindowForFreshSuggestion() {
        guard postExhaustionAcceptanceState.consumeHeldPress() else { return }
        logStage(
            "held-press-dropped",
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: "Dropped a Tab held during post-acceptance regeneration instead of accepting the "
                + "continuation it predates."
        )
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

        let keptTypingPrediction = retainTypingPrediction(typing: typedCharacters)
        if !keptTypingPrediction { cancelPredictionWork(preservingContinuation: true) }

        if advancedSession.isExhausted {
            if keptTypingPrediction {
                // Consuming the visible partial is not accepting unseen words. Keep decoding,
                // release Tab, and let a later validated partial reveal the next complete word.
                interactionState.clearSuggestion()
                hideOverlay(reason: "Overlay hidden while a matching prediction continues.")
                state = .generating
                return true
            }
            markPreparedContinuationCommitted(after: session)
            completeActiveSuggestion(
                reason: "Overlay hidden because the user typed through the rest of the suggestion.",
                scheduleNextPrediction: true,
                awaitHostPublish: true,
                stage: "typed-match-exhausted",
                message: "The user typed the remaining suggestion characters exactly."
            )
            return true
        }

        if keptTypingPrediction {
            suggestionStreamingState.recordRendered(advancedSession.remainingText)
        }
        state = .ready
        // Nearly typed through: fetch what comes next into the cache now, so exhausting this
        // suggestion lands on a ready one instead of a blank gap (see `prefetchContinuation`).
        if let rawContext = focusModel.snapshot.context {
            prefetchContinuation(after: advancedSession, rawContext: rawContext)
        }
        if isHoldingForHostMarkedText {
            // The host's own prediction still occupies the ghost's spot; the advanced tail stays
            // hidden until a snapshot without marked text reconciles and re-presents it.
            if overlayState.isVisible {
                hideOverlay(reason: Self.hostMarkedTextHoldReason)
            }
        } else if !overlayController.advanceInline(to: advancedSession.remainingText, insertedText: typedCharacters) {
            // Same slide as Tab acceptance; the user typed the next characters, so the caret
            // traveled by exactly them. Fall back to the (session-start) caret anchor only if the
            // slide can't apply.
            presentOverlay(
                text: advancedSession.remainingText,
                at: session.baseContext.caretRect,
                context: session.baseContext
            )
        } else {
            recordSuggestionPresentation(context: session.baseContext)
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
        // The dying session is exactly what a backspace-rollback wants restored a moment later;
        // remember it (string-only) before the state is torn down.
        if let session = interactionState.activeSession, !session.kind.isCorrection {
            suggestionAnchorCache.record(
                identityKey: session.baseContext.suggestionSessionIdentityKey,
                precedingText: session.baseContext.precedingText,
                fullText: session.fullText
            )
        }
        cancelPredictionWork()
        retireSuggestion(reason: reason, clearDiagnostics: clearDiagnostics)
        // The tail a deferred screen-context change was waiting to retire is gone, and the caller
        // decides whether to predict; left pending, it would cancel that newer work on waking.
        settleDeferredScreenContextChange()
    }

    func completeActiveSuggestion(
        reason: String,
        scheduleNextPrediction: Bool,
        awaitHostPublish: Bool = false,
        stage: String,
        message: String
    ) {
        let generation = latestGenerationNumber
        retireSuggestion(reason: reason, preservingContinuation: preparedContinuation?.isCommitted == true)
        // Same as invalidation: the tail is consumed and the prediction below must not be cancelled.
        settleDeferredScreenContextChange()
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

    /// Marks the session's suggestion accepted in the quality counters, once per suggestion: only
    /// the first chunk counts, so word-by-word walks of one suggestion add nothing further and the
    /// acceptance rate stays suggestions-accepted over suggestions-shown.
    private func recordSuggestionAcceptedIfFirstChunk(of session: ActiveSuggestionSession) {
        guard session.consumedCharacterCount == 0 else { return }
        qualityMetricsStore.recordAcceptedSuggestion()
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
        let anchor = CaretLayoutRepair.layoutRepairedAnchor(
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
            bundleIdentifier: context.bundleIdentifier,
            focusedURLString: context.focusedURLString,
            isCaretAtEndOfLine: context.isCaretAtEndOfLine,
            observedCharWidth: context.observedCharWidth,
            isRightToLeft: isRightToLeft,
            focusChangeSequence: context.focusChangeSequence,
            focusedInputIdentityKey: context.focusedInputIdentityKey,
            isCorrection: isCorrection,
            resolvedFieldStyle: context.resolvedFieldStyle,
            hostTextMetrics: context.hostTextMetrics,
            isWebContentField: context.isWebContentField,
            hasTrailingContent: context.hasTrailingContent,
            isSingleLineField: context.isSingleLineField,
            elementFrameRect: context.elementFrameRect,
            lineTextBeforeCaret: GhostCaretRefinement.paragraphTextBeforeCaret(in: context.precedingText),
            wrappedRun: context.observedContentEdges?.wrappedRun,
            observedContentEdges: context.observedContentEdges,
            isCaretLineVerticallyUncalibrated: anchor.isCaretLineVerticallyUncalibrated
        )
        // An identical text/geometry update is a no-op: an old visible panel must not satisfy a
        // new input's timing measurement. Inline advances record through the same helper below.
        if overlayPresenter.present(text: text, geometry: geometry, previousState: overlayState) {
            recordSuggestionPresentation(context: context, isCorrection: isCorrection)
        }
    }

    /// Records an accepted presentation state update, including the cheap inline-tail path. The
    /// controller publishes state synchronously, before any optional opacity animation completes;
    /// this is submission latency, not a compositor timestamp or a judgment of useful text.
    private func recordSuggestionPresentation(context: FocusedInputContext, isCorrection: Bool = false) {
        if CotabbyDebugOptions.isEnabled, overlayState.isVisible,
           let measurement = suggestionPresentationTiming.presented(
               identity: FocusedInputIdentity(
                   elementIdentifier: context.elementIdentifier,
                   focusChangeSequence: context.focusChangeSequence
               ),
               at: ProcessInfo.processInfo.systemUptime
           ) {
            CotabbyLogger.suggestion.debug("First suggestion presentation submitted after input", metadata: [
                "stage": "first-presentation",
                "request_id": .string(latestRequestID ?? "req_none"),
                "input_kind": .string(measurement.inputKind),
                "input_to_first_presentation_ms": .stringConvertible(measurement.milliseconds),
                "is_correction": .stringConvertible(isCorrection)
            ])
        }
    }

    /// Mirrors the repair outcome into the structured JSONL stream so a misplaced overlay can be
    /// joined to the exact gate decision via `request_id`. The metadata deliberately carries the
    /// estimate-vs-AX vertical delta and which host measurements calibrated the layout, because
    /// field reports of "ghost is N lines off" are only diagnosable from those numbers.
    /// Deliberately not routed through `logStage`: this is a geometry-specific event rather than a
    /// user-visible pipeline stage.
    private func logCaretLayoutRepair(
        anchor: CaretLayoutRepair.LayoutRepairedAnchor,
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
            metadata["vertically_calibrated"] = .stringConvertible(estimate.isVerticallyCalibrated)
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
        overlayPresenter.hide(reason: reason)
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
