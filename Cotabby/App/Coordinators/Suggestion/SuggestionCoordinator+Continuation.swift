import Foundation

/// Prepares one next-word continuation while a local word ending or correction is visible.
/// The coordinator owns this short-lived work because it must coordinate the engine, permission
/// gates, and editor publication. The pure plan owns the hypothetical text; no AX object is kept.
extension SuggestionCoordinator {
    /// One coordinator-owned lookahead, retained only until its source word is consumed or invalidated.
    /// Keeping its plan separate from the live session prevents hypothetical text from entering AX
    /// reconciliation before the editor has actually published the accepted edit.
    struct PreparedContinuation {
        let plan: SuggestionContinuationPlan
        let sourceSession: ActiveSuggestionSession
        var text: String?
        var latency: TimeInterval = 0
        var awaitingCommit = false

        func belongs(to session: ActiveSuggestionSession) -> Bool {
            sourceSession.baseContext == session.baseContext
                && sourceSession.fullText == session.fullText && sourceSession.kind == session.kind
        }
    }

    func cancelPreparedContinuation() {
        continuationWorkController.cancelAll()
        preparedContinuation = nil
    }

    /// Only terminal word endings need another request. A model-provided phrase stays in its
    /// original session; prefetch never replaces those words with a different model guess.
    func prepareContinuation(after session: ActiveSuggestionSession, rawContext: FocusedInputSnapshot) {
        // Uncommitted lookahead is new work, so keep it on-device. The coordinator intentionally
        // has no endpoint URL; allowing all configured endpoints here would also send hypothetical
        // corrections to hosted servers. Their already-returned phrases still use the same buffer.
        guard settingsSnapshot.selectedEngine != .openAICompatible,
              !userDefaults.bool(forKey: Self.speculativePrefetchDisabledDefaultsKey),
              currentDisabledReason(focusSnapshot: focusModel.snapshot) == nil else { return }
        let plan: SuggestionContinuationPlan?
        if case let .correction(typo) = session.kind {
            plan = TypoCorrectionReplacementPlanner.plan(precedingText: rawContext.precedingText,
                expectedTypo: typo, correctedWord: session.fullText, requiresTrailingSpace: false)
                .flatMap { SuggestionContinuationPlan.correcting($0, in: rawContext) }
        } else {
            guard session.consumedCharacterCount == 0,
                  CaretWordContext.unfinishedWord(in: rawContext.precedingText) != nil,
                  !session.fullText.contains(where: { $0.isWhitespace }) else { return }
            plan = SuggestionContinuationPlan.completing(session.fullText, in: rawContext)
        }
        guard let plan else { return }
        cancelPreparedContinuation()
        preparedContinuation = PreparedContinuation(plan: plan, sourceSession: session)

        // Construct a hypothetical request without materializing it into ContextBuffer: that
        // buffer belongs to observed editor text, and advancing it here would stale the visible word.
        let context = FocusedInputContext(snapshot: plan.requestSnapshot, generation: session.baseContext.generation)
        let request = SuggestionRequestFactory.buildRequest(context: context, settings: settingsSnapshot,
            configuration: configuration, clipboardContext: pinnedClipboardContext(rawContext: rawContext),
            visualContextSummary: permissionManager.screenRecordingGranted
                ? visualContextCoordinator.excerpt(for: session.baseContext) : nil).request
        continuationWorkController.replaceDebouncedWork(delayMilliseconds: 0) { [weak self] workID in
            guard let self else { return }
            await self.awaitCachedGenerationContextResetIfNeeded()
            guard self.continuationWorkController.isCurrent(workID) else { return }
            do {
                let result = try await self.suggestionEngine.generateSuggestion(for: request)
                guard !Task.isCancelled, self.continuationWorkController.isCurrent(workID) else { return }
                guard case .show = self.completionPresentation(text: result.text, context: context, isFinal: true),
                      !TrailingDuplicationFilter.duplicatesTrailingText(result.text, trailingText: context.trailingText)
                else {
                    self.finishUnavailableContinuation()
                    return
                }
                self.preparedContinuation?.text = plan.continuation(from: result.text)
                self.preparedContinuation?.latency = result.latency
                self.attachPreparedContinuationOrAwaitPublication()
            } catch {
                guard self.continuationWorkController.isCurrent(workID) else { return }
                self.finishUnavailableContinuation()
            }
        }
    }

    /// Acceptance changes which text we expect next, but does not restart the prepared request.
    /// A result that arrives before AX catches up stays buffered and cannot become an insertion.
    @discardableResult
    func markPreparedContinuationCommitted(after session: ActiveSuggestionSession) -> Bool {
        guard preparedContinuation?.belongs(to: session) == true else { return false }
        preparedContinuation?.awaitingCommit = true
        return true
    }

    private func attachPreparedContinuationOrAwaitPublication() {
        guard let prepared = preparedContinuation, let text = prepared.text, !text.isEmpty else {
            finishUnavailableContinuation()
            return
        }
        if !prepared.sourceSession.kind.isCorrection,
           let active = interactionState.activeSession, prepared.belongs(to: active) {
            guard let raw = focusModel.snapshot.context,
                  SuggestionContinuationPlan.sameFocusedField(raw, prepared.plan.sourceSnapshot),
                  raw.trailingText == prepared.plan.sourceSnapshot.trailingText,
                  raw.selection.length == 0, !raw.isSecure,
                  raw.precedingText.hasPrefix(active.baseContext.precedingText),
                  active.fullText.hasPrefix(String(raw.precedingText.dropFirst(active.baseContext.precedingText.count)))
            else { cancelPreparedContinuation(); return }
            let previousText = active.remainingText
            guard let extended = interactionState.extendPrediction(
                fullText: active.fullText + text, expectedSession: active) else { return }
            cancelPreparedContinuation()
            // The first word remains the visible acceptance boundary until the user finishes it.
            // Usually only the hidden buffer changed, so avoid an unnecessary overlay re-layout.
            if extended.remainingText != previousText {
                state = .ready(text: extended.remainingText, latency: extended.latency)
                reconcileActiveSession(with: focusModel.snapshot)
            }
            return
        }
        _ = usePreparedContinuationIfPossible()
    }

    /// Returns true when published text is covered by a prepared request (ready or still running).
    /// Exact field and content checks keep hypothetical work out of a different editor or caret.
    @discardableResult
    func usePreparedContinuationIfPossible() -> Bool {
        guard let prepared = preparedContinuation, prepared.awaitingCommit,
              let raw = focusModel.snapshot.context,
              currentDisabledReason(focusSnapshot: focusModel.snapshot) == nil,
              preparedTextAdjustment(prepared, for: raw) != nil else { return false }
        guard let text = prepared.text else { return true }
        // Exact publication has arrived. Retire the acceptance poll before consuming its plan;
        // otherwise a queued poll can see no plan and start a duplicate request while apply waits
        // for presentation. That older callback no longer owns this context transition.
        hostPublishPollGeneration &+= 1
        cancelPreparedContinuation()
        workController.replaceDebouncedWork(delayMilliseconds: 0) { [weak self] workID in
            guard let self, let live = self.focusModel.snapshot.context,
                  let trimsSpace = self.preparedTextAdjustment(prepared, for: live) else { return }
            let adjustedText = trimsSpace ? String(text.drop(while: { $0 == " " })) : text
            let context = self.interactionState.materializeContext(from: live)
            await self.apply(result: SuggestionResult(generation: context.generation, rawText: adjustedText,
                text: adjustedText, latency: prepared.latency), workID: workID)
        }
        return true
    }

    /// The optional auto-space and a user-typed separating space both commit the same word. They
    /// are the only deviation accepted from a prefetch target, and consume its one leading space.
    private func preparedTextAdjustment(_ prepared: PreparedContinuation, for raw: FocusedInputSnapshot) -> Bool? {
        if prepared.plan.matchesTarget(raw) { return false }
        guard prepared.plan.matchesTargetWithJoiningSeparator(raw) else { return nil }
        return true
    }

    private func finishUnavailableContinuation() {
        let shouldRefresh = preparedContinuation?.awaitingCommit == true
        let targetPublished = preparedContinuation.flatMap { prepared in
            focusModel.snapshot.context.flatMap { preparedTextAdjustment(prepared, for: $0) }
        } != nil
        cancelPreparedContinuation()
        // A failed optional prefetch never replaces a useful visible word with an error state.
        // Once the source has been accepted, ordinary prediction remains the fallback.
        if shouldRefresh {
            if targetPublished { schedulePrediction() }
            else { schedulePredictionAfterHostPublishDelay(requiresTextChange: true) }
        }
    }
}
