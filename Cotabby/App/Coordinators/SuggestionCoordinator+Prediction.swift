import Foundation
import Logging

/// File overview:
/// Debounce, generation, stale-result handling, and visual-context-triggered rescheduling.
/// This is the async half of the coordinator's state machine.
extension SuggestionCoordinator {
    // MARK: - Prediction Pipeline

    /// How recent a focus capture must be for the pipeline to trust it instead of paying another
    /// synchronous AX walk. Chosen to cover the debounce window plus scheduling jitter: a capture
    /// younger than this was taken after the keystroke that scheduled the current work, so a fresh
    /// read cannot observe a different editing context without the downstream generation guards
    /// also tripping.
    static let freshSnapshotReuseWindowMilliseconds = 30

    func schedulePrediction(consumedDelayMilliseconds: Int = 0) {
        // Any normal reschedule supersedes an outstanding speculative bet (its work id retires the
        // in-flight task; this retires the signature exemption so a late result cannot sneak in).
        pendingSpeculativeSignature = nil
        if let disabledReason = currentDisabledReason(focusSnapshot: focusModel.snapshot) {
            disablePredictions(reason: disabledReason)
            return
        }

        // The debounce window adapts to the last generation latency: snappier when the model is
        // fast, calmer when it is slow (fewer doomed generations to cancel). The configured value
        // is the fallback until a first latency exists.
        let debounceMilliseconds = DebouncePolicy.milliseconds(
            lastGenerationLatencyMilliseconds: latestLatencyMilliseconds,
            fallback: settingsSnapshot.debounceMilliseconds
        )
        // The debounce clock starts at the keystroke, not here. The host-publish poll has already
        // consumed real wall time waiting for the host to publish the keystroke to AX, and that
        // wait collapses bursts just as well as sleeping does. Stacking the full debounce on top
        // of the publish wait was pure added latency, so only the unconsumed remainder is slept.
        let remainingDelay = max(0, debounceMilliseconds - consumedDelayMilliseconds)

        // Task cancellation in Swift is cooperative, so we also use an explicit work id.
        // That gives us strict "latest request wins" semantics even if an old task wakes up late.
        let workID = workController.replaceDebouncedWork(
            delayMilliseconds: remainingDelay
        ) { [weak self] workID in
            await self?.generateFromCurrentFocus(workID: workID)
        }

        // Equality guards keep repeated keystrokes from republishing identical state: every
        // @Published write re-renders every coordinator observer (menu bar label included).
        if state != .debouncing {
            state = .debouncing
        }
        logStage(
            "debouncing",
            workID: workID,
            message: "Debouncing (\(debounceMilliseconds)ms window, \(remainingDelay)ms remaining) before generating."
        )
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
        // The host-publish poll usually captured one milliseconds ago, though, so a fresh-enough
        // capture is reused instead of paying another synchronous AX walk back to back.
        focusModel.refreshIfStale(maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
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
        // pile onto a broken word), presents a green correction, or automatically fixes a completed
        // word after Space. Native correction is instant and needs no model generation, so it is
        // handled synchronously and returns before any request runs.
        if handleTypoGate(rawContext: rawContext, workID: workID) {
            return
        }

        let context = interactionState.materializeContext(from: rawContext)
        // A cached suggestion consistent with the live text re-shows instantly: no debounce paid,
        // no model run. Covers backspace rollback, type-through re-entry, and field return.
        if restoreSuggestionFromAnchorCache(context: context, workID: workID) {
            return
        }
        // Screen Recording is optional. Re-check it live so a cached excerpt captured before the user
        // revoked the permission can never be injected during the 2s permission-poll window.
        let visualContextSummary = permissionManager.screenRecordingGranted
            ? visualContextCoordinator.excerpt(for: context)
            : nil
        let clipboardContext = pinnedClipboardContext(rawContext: rawContext)
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

    /// Re-shows the freshest cached suggestion consistent with the live text, if any survives the
    /// same display guards a fresh generation passes. Returns true when a suggestion was restored
    /// (the caller skips generation entirely). The win is exactly the common editing moments:
    /// deleting a typo, retyping suggested words after an invalidation, returning to a field.
    private func restoreSuggestionFromAnchorCache(context: FocusedInputContext, workID: UInt64) -> Bool {
        guard !userDefaults.bool(forKey: Self.anchorReuseDisabledDefaultsKey) else { return false }
        guard context.selection.length == 0, !context.isSecure else { return false }
        guard let remainder = suggestionAnchorCache.remainder(
            identityKey: context.focusedInputIdentityKey,
            precedingText: context.precedingText
        ), !remainder.isEmpty else { return false }

        // Same display guards `apply` enforces on a fresh result. The remainder is a suffix of a
        // suggestion that already passed the normalizer and seam guard for this exact text path,
        // so only the guards that depend on CURRENT field state need re-checking.
        if TrailingDuplicationFilter.duplicatesTrailingText(remainder, trailingText: context.trailingText) {
            return false
        }
        if let pendingAcceptedTail = lastAcceptedTail,
           SuggestionSessionReconciler.isStaleAcceptanceEcho(
               resultText: remainder,
               acceptedChunk: pendingAcceptedTail.text,
               currentPrecedingText: context.precedingText,
               acceptedPrecedingText: pendingAcceptedTail.precedingText
           ) {
            return false
        }

        lastAcceptedTail = nil
        latestGenerationNumber = context.generation
        latestLatencyMilliseconds = 0
        let session = interactionState.startSession(
            fullText: remainder,
            liveContext: context,
            latency: 0
        )
        applySessionDiagnostics(session, acceptanceAction: "Restored a cached suggestion.")
        state = .ready(text: session.remainingText, latency: session.latency)
        presentOverlay(
            text: session.remainingText,
            at: context.caretRect,
            context: context,
            isRightToLeft: TextDirectionDetector.isRightToLeft(context.precedingText)
        )
        logStage(
            "anchor-restore",
            workID: workID,
            generation: context.generation,
            message: "Re-showed a cached suggestion without regenerating.",
            normalizedOutput: remainder
        )
        return true
    }

    /// Starts the next generation immediately after a final-chunk accept, against the snapshot
    /// the host is expected to publish, instead of idling through the publish poll first. The
    /// poll keeps running as the validator: a matching publish lets this result through
    /// (`pendingSpeculativeSignature` in `apply`), a mismatch schedules a normal regeneration
    /// whose newer work id retires this one automatically.
    func dispatchSpeculativePostAcceptanceGeneration(
        rawContext: FocusedInputSnapshot,
        insertionChunk: String
    ) {
        guard !userDefaults.bool(forKey: Self.speculativePrefetchDisabledDefaultsKey) else { return }
        guard !insertionChunk.isEmpty else { return }

        let optimistic = SpeculativeAcceptanceContext.optimisticSnapshot(
            after: rawContext,
            inserting: insertionChunk
        )

        // Same pre-generation gates the ordinary cycle applies, minus their UI side effects: a
        // speculative request must not spend a decode on text the normal path would refuse (too
        // little text) or suppress (typo gate). The post-publish regeneration still runs the full
        // gate with its correction semantics; declining here only skips the speculation.
        guard SuggestionRequestFactory.shouldGenerateSuggestion(for: optimistic.precedingText) else {
            return
        }
        if settingsSnapshot.suppressCompletionsOnTypo,
           let trailingWord = CurrentWordExtractor.extractTrailingWord(from: optimistic.precedingText)?.result.word,
           spellChecker.isTypo(trailingWord) {
            return
        }

        let context = interactionState.materializeContext(from: optimistic)
        pendingSpeculativeSignature = context.contentSignature

        let visualContextSummary = permissionManager.screenRecordingGranted
            ? visualContextCoordinator.excerpt(for: context)
            : nil
        // The pinned clipboard verdict, not a fresh filter pass: a speculative request that
        // re-evaluated relevance against the optimistic prefix could flip the verdict and rewrite
        // the prompt head mid-session, breaking prompt-byte continuity with the ordinary cycle
        // (and the llama KV prefix reuse that depends on it).
        let clipboardContext = pinnedClipboardContext(rawContext: optimistic)
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

        let workID = workController.replaceDebouncedWork(delayMilliseconds: 0) { [weak self] workID in
            guard let self else { return }
            self.dispatchGeneration(request: request, workID: workID)
        }
        state = .generating
        logStage(
            "speculative-generating",
            workID: workID,
            generation: context.generation,
            message: "Started the post-acceptance generation against the expected post-insert text.",
            prompt: requestBuildResult.promptPreview
        )
    }

    /// Runs the engine generation for `request` as the replaceable work for `workID`, applying the
    /// result (or failure) only while it is still the current work. Extracted from
    /// `generateFromCurrentFocus` so that function stays within the project's complexity budget.
    private func dispatchGeneration(request: SuggestionRequest, workID: UInt64) {
        // A new generation starts a new stream; the previous request's rendered-partial state
        // must not gate the new partials' monotonic checks. `isStreamDrainScheduled` is left
        // alone on purpose: an already-enqueued drain block cannot be unscheduled, and it
        // self-heals either way — it finds nil and clears the flag, or it finds a partial the
        // new generation queued in the meantime and renders it under the same work-id guards.
        // Resetting the flag here would instead double-schedule a drain for one partial.
        streamRenderedText = nil
        pendingStreamPartial = nil
        // Streaming the ghost text token-by-token is opt-in. Read the flag here on the main actor so
        // the work closure captures a plain Bool. When off, the closure passes no `onPartial`, so the
        // engine skips its per-token main-actor hops entirely and the suggestion appears once, fully
        // formed, through `apply` below; when on, each partial renders as an acceptable session the
        // user can Tab into early.
        let shouldStreamPartials = settingsSnapshot.streamSuggestionsWhileGenerating
        workController.replaceGenerationWork(for: workID) { [weak self] in
            guard let self else {
                return
            }

            do {
                let onPartial: (@MainActor (SuggestionResult) -> Void)?
                if shouldStreamPartials {
                    onPartial = { [weak self] partial in self?.queueStreamedPartial(partial, workID: workID) }
                } else {
                    onPartial = nil
                }
                let result = try await suggestionEngine.generateSuggestion(
                    for: request,
                    onPartial: onPartial
                )
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

    /// Resolves the clipboard prompt section under the pinning policy documented on
    /// `clipboardPrefaceMemo`: an accepted (non-nil) verdict is reused for the rest of the field
    /// session so the prompt head stays stable and the engine's KV common prefix survives; a nil
    /// verdict re-evaluates per request because it adds nothing to the prompt and the clipboard
    /// may only become relevant once more text is typed. A new copy or a field switch always
    /// re-evaluates.
    private func pinnedClipboardContext(rawContext: FocusedInputSnapshot) -> String? {
        guard settingsSnapshot.isClipboardContextEnabled else {
            return nil
        }

        let changeCount = clipboardContextProvider.currentChangeCount
        if let memo = clipboardPrefaceMemo,
           memo.focusSequence == rawContext.focusChangeSequence,
           memo.changeCount == changeCount,
           memo.value != nil {
            return memo.value
        }

        // Same bounded window the downstream distiller sees, so the relevance gate and the
        // per-line filter can't disagree about what "shares tokens with the prefix" means.
        let truncatedPrefix = SuggestionRequestFactory.truncatedPromptPrefix(
            from: rawContext.precedingText,
            configuration: configuration,
            engine: settingsSnapshot.selectedEngine
        )
        let value = clipboardRelevanceFilter.filter(
            clipboard: clipboardContextProvider.currentContext(),
            pasteboardChangeCount: changeCount,
            precedingText: truncatedPrefix
        )
        clipboardPrefaceMemo = ClipboardPrefaceMemo(
            focusSequence: rawContext.focusChangeSequence,
            changeCount: changeCount,
            value: value
        )
        return value
    }

    // MARK: - Streamed partial rendering

    /// Coalesces streamed partials to at most one render per runloop turn. Tokens arrive every
    /// 10-50ms from the engine, and rendering each one would stack session updates and overlay
    /// layout on the main actor; latest-wins coalescing bounds that work while the authoritative
    /// final result still arrives through `apply`.
    private func queueStreamedPartial(_ partial: SuggestionResult, workID: UInt64) {
        guard workController.isCurrent(workID) else {
            return
        }
        pendingStreamPartial = PendingStreamPartial(result: partial, workID: workID)
        guard !isStreamDrainScheduled else {
            return
        }
        isStreamDrainScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.drainStreamedPartial()
        }
    }

    private func drainStreamedPartial() {
        isStreamDrainScheduled = false
        guard let pending = pendingStreamPartial else {
            return
        }
        pendingStreamPartial = nil
        applyStreamedPartial(pending.result, workID: pending.workID)
    }

    /// Renders one streamed partial as a real, acceptable session.
    ///
    /// A real session rather than a cosmetic overlay because acceptance gates on the live session
    /// (never on `state`), so the user can Tab into a stream the moment the first words appear;
    /// accepting cancels the in-flight work (work id bump), freezing the suggestion at what was
    /// streamed. Renders are monotonic (`StreamedGhostTextPolicy`) so reordered hops and
    /// normalizer rewrites never shrink visible ghost text, and the materialize check stops
    /// partials the moment the field text moves on without a keystroke (a keystroke already
    /// bumped the work id before this runs).
    private func applyStreamedPartial(_ partial: SuggestionResult, workID: UInt64) {
        guard workController.isCurrent(workID) else {
            return
        }
        guard StreamedGhostTextPolicy.isRenderableExtension(
            candidate: partial.text,
            currentlyRendered: streamRenderedText
        ) else {
            return
        }
        guard let rawContext = focusModel.snapshot.context else {
            return
        }

        let liveContext = interactionState.materializeContext(from: rawContext)
        guard liveContext.generation == partial.generation else {
            return
        }

        // Streaming half of the seam guard: the pure junk-run rule only. The spell-lookup half
        // is an XPC and partials drain at token cadence, so it stays on the final apply, which
        // authoritatively replaces or suppresses whatever streamed.
        guard CompletionSeamGuard.allowsStreamedPartial(
            precedingText: liveContext.precedingText,
            completion: partial.text
        ) else {
            return
        }

        _ = interactionState.startSession(
            fullText: partial.text,
            liveContext: liveContext,
            latency: partial.latency
        )
        streamRenderedText = partial.text
        presentOverlay(
            text: partial.text,
            at: liveContext.caretRect,
            context: liveContext,
            isRightToLeft: TextDirectionDetector.isRightToLeft(liveContext.precedingText)
        )
    }

    /// Runs the typo gate for the current word. Returns `true` when it handled the cycle by suppressing,
    /// offering, or applying a correction; `false` proceeds with a normal continuation. Kept separate
    /// so `generateFromCurrentFocus` stays within the project's cyclomatic-complexity budget.
    private func handleTypoGate(rawContext: FocusedInputSnapshot, workID: UInt64) -> Bool {
        switch TypoGate.resolve(
            precedingText: rawContext.precedingText,
            settings: TypoGate.Settings(
                suppressCompletionsOnTypo: settingsSnapshot.suppressCompletionsOnTypo,
                offerTypoCorrections: settingsSnapshot.offerTypoCorrections,
                automaticallyFixTypos: settingsSnapshot.automaticallyFixTypos
            ),
            isTypo: { spellChecker.isTypo($0) },
            bestCorrection: {
                bestCorrection(
                    for: $0,
                    precedingText: rawContext.precedingText
                )
            }
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
        case let .offerCorrection(word, correctedWord):
            presentCorrection(
                typoWord: word,
                correctedWord: correctedWord,
                rawContext: rawContext,
                workID: workID
            )
            return true
        case let .applyCorrection(word, correctedWord):
            applyAutomaticCorrection(
                typoWord: word,
                correctedWord: correctedWord,
                rawContext: rawContext,
                workID: workID
            )
            return true
        }
    }

    /// Routes the typo to one enabled language-specific SymSpell index. The dictionaries remain
    /// separate because frequency counts from different corpora are not comparable. Ambiguous
    /// multilingual context, a cold index, or a missing SymSpell candidate all fall back to the
    /// user's automatic-language macOS spell checker.
    private func bestCorrection(for word: String, precedingText: String) -> String? {
        let enabledLanguages = SpellingDictionaryCatalog.languages(
            for: settingsSnapshot.enabledSpellingDictionaryCodes
        )
        guard let language = spellingLanguageResolver.resolve(
            precedingText: precedingText,
            currentWord: word,
            enabledLanguages: enabledLanguages
        ) else {
            return spellChecker.bestCorrection(for: word)
        }

        return symSpellCorrector.bestCorrection(for: word, language: language)
            ?? spellChecker.bestCorrection(for: word)
    }

    /// Replaces a completed typo after Space without creating a visible correction session.
    ///
    /// Automatic mutation is intentionally limited to a committed word boundary. The shared planner
    /// revalidates the exact trailing word and requires that Space to still be present, so a stale AX
    /// snapshot or a user who resumed typing cannot make Cotabby delete an unrelated suffix.
    private func applyAutomaticCorrection(
        typoWord: String,
        correctedWord: String,
        rawContext: FocusedInputSnapshot,
        workID: UInt64
    ) {
        let liveContext = interactionState.materializeContext(from: rawContext)
        latestGenerationNumber = liveContext.generation
        guard let replacement = TypoCorrectionReplacementPlanner.plan(
            precedingText: rawContext.precedingText,
            expectedTypo: typoWord,
            correctedWord: correctedWord,
            requiresTrailingSpace: true
        ) else {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the automatic correction target changed.")
            state = .idle
            logStage(
                "typo-auto-correction-stale",
                workID: workID,
                generation: liveContext.generation,
                message: "Skipped automatic correction because the completed word no longer matched."
            )
            return
        }

        guard suggestionInserter.replace(
            deletingUTF16Count: replacement.deletingUTF16Count,
            with: replacement.replacementText
        ) else {
            let message = suggestionInserter.lastErrorMessage ?? "Automatic correction insertion failed."
            cancelPredictionWork()
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because automatic correction insertion failed.")
            state = .idle
            logStage(
                "typo-auto-correction-failed",
                workID: workID,
                generation: liveContext.generation,
                message: message,
                normalizedOutput: correctedWord
            )
            return
        }

        focusModel.invalidateTransientCaretCaches()
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: false)
        hideOverlay(reason: "Overlay hidden because Cotabby automatically fixed a typo.")
        latestAcceptanceAction = "Automatically corrected \"\(typoWord)\" to \"\(correctedWord)\"."
        state = .idle
        logStage(
            "typo-auto-corrected",
            workID: workID,
            generation: liveContext.generation,
            message: "Automatically replaced the completed misspelled word after Space.",
            normalizedOutput: correctedWord
        )
        // Synthetic replacement is asynchronous from the host editor's perspective. Poll until AX
        // publishes the corrected text before asking for the next continuation.
        schedulePredictionAfterHostPublishDelay()
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

    /// Empty-result bookkeeping for `apply`, extracted to keep that function inside the
    /// complexity budget as its guard chain grew.
    private func discardEmptyResult(_ result: SuggestionResult, workID: UInt64) {
        clearSuggestion()
        hideOverlay(reason: "Overlay hidden because the model returned an empty continuation.")
        state = .idle
        // The router already counted engine-attributed suppressions (normalizer, confidence
        // floor); only the unattributed "model produced nothing" case needs a ledger entry.
        if result.suppressionReason == nil {
            qualityMetricsStore.recordSuppressed(reason: "emptyUnattributed")
        }
        logStage(
            "empty-result",
            workID: workID,
            generation: result.generation,
            message: "Model returned an empty or whitespace-only continuation after normalization.",
            rawOutput: result.rawText,
            normalizedOutput: result.text
        )
    }

    private static func seamSuppressionReason(for verdict: CompletionSeamGuard.Verdict) -> String {
        if case .seamMisspelling = verdict {
            return "seamMisspelling"
        }
        return "seamJunkPunctuationRun"
    }

    /// Promotes a generated result to `ready` only when it is still fresh for the current field.
    func apply(result: SuggestionResult, workID: UInt64) async {

        guard workController.isCurrent(workID) else {

            return
        }

        // The free-running focus poll keeps capturing while the engine generates, so a fresh
        // capture often already exists here; only pay a synchronous AX walk when it does not.
        // Any keystroke during generation bumped the work id (checked above), and non-keyboard
        // edits are caught by the generation guard below on the materialized context.
        focusModel.refreshIfStale(maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
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
        // thinking, we drop the answer instead of showing a suggestion for old content. One
        // exception: a speculative post-acceptance generation was built against text the host had
        // not published yet, so its generation predates the live one by construction. When the
        // live content now matches the signature the speculation was built against, the bet paid
        // off and the result is exactly current.
        let isPaidOffSpeculation = pendingSpeculativeSignature != nil
            && pendingSpeculativeSignature == liveContext.contentSignature
        if isPaidOffSpeculation {
            pendingSpeculativeSignature = nil
        }

        guard isPaidOffSpeculation || liveContext.generation == result.generation else {

            latestRawModelOutput = SuggestionDebugLogger.debugPreview(result.rawText)
            // Lifecycle discards are counted under their own reasons so `generated` always equals
            // `shown` plus the suppression histogram; without this, every drop here silently
            // inflated the generated count against the others.
            qualityMetricsStore.recordSuppressed(reason: "discardedStaleContext")
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
            discardEmptyResult(result, workID: workID)
            return
        }

        guard liveContext.selection.length == 0 else {
            clearSuggestion(clearDiagnostics: true)
            hideOverlay(reason: "Overlay hidden because text is selected.")
            state = .idle
            qualityMetricsStore.recordSuppressed(reason: "discardedSelection")
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
            qualityMetricsStore.recordSuppressed(reason: "discardedAcceptEcho")
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

        // Last line of defense before display: junk punctuation runs and mid-word splices that
        // misspell the word being typed read as glitches, so showing nothing beats showing them.
        // The spell lookup runs at most once per generation and only in the mid-word case.
        let seamVerdict = CompletionSeamGuard.verdict(
            precedingText: liveContext.precedingText,
            completion: result.text,
            isKnownWord: { !spellChecker.isTypo($0) }
        )
        if seamVerdict != .allow {
            clearSuggestion()
            hideOverlay(reason: "Overlay hidden because the completion failed the seam guard.")
            state = .idle
            qualityMetricsStore.recordSuppressed(reason: Self.seamSuppressionReason(for: seamVerdict))
            logStage(
                "seam-suppressed",
                workID: workID,
                generation: result.generation,
                message: "Suppressed completion at the caret seam: \(seamVerdict).",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        latestLatencyMilliseconds = Int(result.latency * 1000)
        latestGenerationNumber = liveContext.generation
        // One shown event per suggestion: this is the only place a fresh generation becomes
        // visible (re-presentations after partial accepts reuse the same session).
        qualityMetricsStore.recordShown()
        suggestionAnchorCache.record(
            identityKey: liveContext.focusedInputIdentityKey,
            precedingText: liveContext.precedingText,
            fullText: result.text
        )
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
            newCaretRect: liveContext.caretRect,
            newInputFrameRect: liveContext.inputFrameRect,
            newFocusChangeSequence: liveContext.focusChangeSequence,
            // While the host has not published our own synthetic insert, this snapshot's caret is
            // the pre-insertion one; re-anchoring to it is the left-then-right accept jitter.
            isAwaitingPostInsertionSync: interactionState.isAwaitingPostInsertionSync,
            millisecondsSinceLastAcceptance: lastAcceptanceAt.map {
                Int(Date().timeIntervalSince($0) * 1000)
            }
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
            suggestInIntegratedTerminals: settingsSnapshot.suggestInIntegratedTerminals,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            focusSnapshot: focusSnapshot
        )
    }

    /// Fully disables prediction, clears cached context, and updates UI messaging with the cause.
    func disablePredictions(reason: String) {
        // In a field that stays blocked (capability, per-app, per-domain), every keystroke routes
        // here. Once the pipeline is already torn down for this exact reason there is nothing
        // left to cancel or hide; re-running the teardown only spawns a redundant engine-reset
        // task and republishes identical UI state on each key.
        if isAlreadyDisabled(for: reason) {
            return
        }

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
        if isAlreadyDisabled(for: reason) {
            return
        }

        cancelPredictionWork()
        resetCachedGenerationContext()
        interactionState.resetAll()
        clearSuggestion(clearDiagnostics: true)
        hideOverlay(reason: reason)
        state = .disabled(reason)
        latestStageMessage = "Disabled: \(reason)"
    }

    /// True when a previous teardown already disabled the pipeline for this exact reason and
    /// nothing visible or session-shaped has appeared since. The overlay and session checks are
    /// defensive: any path that shows ghost text or starts a session also moves `state` away from
    /// `.disabled`, but re-running the teardown is cheap insurance if that invariant ever slips.
    private func isAlreadyDisabled(for reason: String) -> Bool {
        guard case .disabled(let currentReason) = state, currentReason == reason else {
            return false
        }

        return !overlayState.isVisible && interactionState.activeSession == nil
    }

    /// True when the no-session clear path still has anything to tear down. With no active
    /// session, most keystrokes arrive with the overlay already hidden and the published
    /// suggestion state already nil; assigning nil to an already-nil `@Published` property still
    /// fires `objectWillChange`, so skipping the redundant clear avoids re-rendering every
    /// coordinator observer on every key. `.disabled` counts as nothing-to-clear because entering
    /// it already ran the full teardown.
    var hasSuggestionArtifactsToClear: Bool {
        if overlayState.isVisible || latestSuggestionPreview != nil || latestPromptPreview != nil {
            return true
        }

        switch state {
        case .idle, .disabled:
            return false
        default:
            return true
        }
    }

    /// Clears the active suggestion and optionally preserves or drops diagnostic breadcrumbs.
    func clearSuggestion(clearDiagnostics: Bool = false) {
        // Drop any pending accepted-tail guard whenever the suggestion state is torn down (user
        // typed, focus changed, predictions disabled). The final-chunk accept re-sets it afterward.
        lastAcceptedTail = nil
        // Stream bookkeeping follows the session it was rendering for.
        streamRenderedText = nil
        pendingStreamPartial = nil
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
        pendingSpeculativeSignature = nil
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
