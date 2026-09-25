import Foundation

/// Bridges the pure typing candidate to the coordinator's existing generation and display paths.
/// There is still only one ordinary engine request. Matching keys preserve its work ID; a model
/// mismatch or expired grace period retires it and lets the normal request factory use fresh AX.
extension SuggestionCoordinator {
    func beginTypingPrediction(for request: SuggestionRequest) {
        clearTypingPrediction()
        // Internal partial collection must not add speculative traffic to configured endpoints.
        // Post-acceptance speculation has its own publication contract and is kept separate.
        guard settingsSnapshot.predictAheadWhileTyping,
              settingsSnapshot.selectedEngine != .openAICompatible,
              pendingSpeculativeContext == nil, !request.context.isSecure,
              request.context.selection.length == 0,
              !userDefaults.bool(forKey: Self.speculativePrefetchDisabledDefaultsKey) else { return }
        // Apple's first snapshot can arrive near the end of a short completion. Retaining a
        // request with no predicted letters added a 150ms catch-up timeout before regenerating
        // for the user's last key. Native llama still benefits from that grace during token decode.
        typingPrediction = TypingPredictionCandidate(
            context: request.context,
            requiresInitialPrediction: settingsSnapshot.selectedEngine == .appleIntelligence
        )
    }

    func clearTypingPrediction() {
        typingPrediction = nil
        typingPredictionExpiry?.cancel()
        typingPredictionExpiry = nil
    }

    /// Called before normal input cancellation, and after a visible session consumes matching
    /// letters. The publication poll validates the observed edit without scheduling a duplicate.
    @discardableResult
    func retainTypingPrediction(typing characters: String) -> Bool {
        guard var candidate = typingPrediction, let raw = focusModel.snapshot.context,
              candidate.append(characters, in: raw, at: ProcessInfo.processInfo.systemUptime) else { return false }
        typingPrediction = candidate
        delayedStreamPresentation?.cancel()
        delayedStreamPresentation = nil
        // A previous partial was measured from an earlier caret. Reset only display monotonicity;
        // request identity and the finalization guard must survive the user's matching letters.
        suggestionStreamingState.resetRenderedText()
        scheduleTypingPredictionExpiry()
        schedulePredictionAfterHostPublishDelay()
        logStage("typing-prediction-retained", workID: currentWorkID,
                 generation: candidate.context.generation,
                 message: "Kept the current prediction while validating matching typed text.")
        return true
    }

    /// The host may publish several keys together. Keep the request only for the exact observed
    /// append path, and replay its latest partial now that its caret anchor can be trusted.
    func keepTypingPredictionAfterHostPublish() -> Bool {
        guard let candidate = typingPrediction, !candidate.typedText.isEmpty,
              let raw = focusModel.snapshot.context, candidate.accepts(raw),
              candidate.expiration(in: raw).map({ $0 > ProcessInfo.processInfo.systemUptime }) ?? true
        else { return false }
        scheduleTypingPredictionExpiry()
        if settingsSnapshot.streamSuggestionsWhileGenerating, !candidate.isFinal,
           let result = candidate.latestResult {
            queueStreamedPartial(result, workID: currentWorkID)
        }
        return true
    }

    /// Partials are collected even when animated streaming is off. That preference controls
    /// presentation; the hidden buffer still lets a complete answer survive intervening typing.
    func receiveTypingPartial(_ result: SuggestionResult, workID: UInt64, showPartials: Bool) {
        guard workController.isCurrent(workID) else { return }
        if var candidate = typingPrediction {
            guard !candidate.isFinal, result.generation == candidate.context.generation else { return }
            guard candidate.receive(result, final: false) else {
                restartTypingPrediction(reason: "Model output diverged from typed text.")
                return
            }
            typingPrediction = candidate
            scheduleTypingPredictionExpiry()
        }
        if showPartials { queueStreamedPartial(result, workID: workID) }
    }

    /// A final answer can arrive before either the typing pause or AX publication. Retain the
    /// immutable answer while waiting, then rebase it once and pass through all normal apply gates.
    /// The work controller owns this suspension, so Tab, dismissal, and focus changes cancel it.
    func finishTypingPrediction(_ result: SuggestionResult, workID: UInt64) async {
        guard var candidate = typingPrediction,
              result.generation == candidate.context.generation else {
            clearTypingPrediction()
            await apply(result: result, workID: workID)
            return
        }
        guard candidate.receive(result, final: true) else {
            restartTypingPrediction(reason: "Final prediction did not cover the typed text.")
            return
        }
        typingPrediction = candidate
        if candidate.typedText.isEmpty, presentationDelay(context: candidate.context) == 0 {
            // The ordinary no-intervening-input case needs only apply's existing focus read.
            // Avoid adding an extra AX walk to the hot path this optimization is meant to shorten.
            clearTypingPrediction()
            await apply(result: result, workID: workID)
            return
        }
        scheduleTypingPredictionExpiry()
        await deliverTypingPredictionWhenReady(result, workID: workID)
    }

    /// Waiting for the editor and pause is separate from collecting the final answer. The same
    /// work ID owns both phases, so a setting change or new field cancels this suspension too.
    private func deliverTypingPredictionWhenReady(_ result: SuggestionResult, workID: UInt64) async {
        while workController.isCurrent(workID), !Task.isCancelled {
            focusModel.refreshIfStale(maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
            guard workController.isCurrent(workID), !Task.isCancelled else { return }
            guard let current = typingPrediction, let raw = focusModel.snapshot.context,
                  current.accepts(raw) else {
                restartTypingPrediction(reason: "The focused text changed before prediction delivery.")
                return
            }
            if let reason = currentDisabledReason(focusSnapshot: focusModel.snapshot) {
                disablePredictions(reason: reason)
                return
            }
            let live = interactionState.materializeContext(from: raw)
            let delay = presentationDelay(context: live)
            if delay == 0, let rebased = current.rebased(result, in: raw, generation: live.generation) {
                let consumed = current.typedText.count
                if consumed > 0, rebased.text.isEmpty {
                    restartTypingPrediction(reason: "Typing exhausted the prepared answer; requesting the next words.")
                    return
                }
                // Delivery itself proved publication. Retire any scheduled validator so it
                // cannot wake after the candidate is cleared and launch a duplicate request.
                hostPublishPollGeneration &+= 1
                clearTypingPrediction()
                if consumed > 0 {
                    logStage("typing-prediction-reused", workID: workID, generation: live.generation,
                             message: "Reused a background prediction after \(consumed) typed characters.")
                }
                // With no intervening input, keep the original generation guard exactly as before.
                await apply(result: consumed > 0 ? rebased : result, workID: workID)
                return
            }
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
        }
    }

    /// A single replaceable timer bounds model catch-up and unpublished input. It never enqueues
    /// another inference request while the current one remains useful.
    private func scheduleTypingPredictionExpiry() {
        typingPredictionExpiry?.cancel()
        typingPredictionExpiry = nil
        guard let candidate = typingPrediction, let raw = focusModel.snapshot.context,
              let deadline = candidate.expiration(in: raw) else { return }
        let workID = currentWorkID
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        typingPredictionExpiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.workController.isCurrent(workID), let current = self.typingPrediction else { return }
            self.focusModel.refreshIfStale(maxAgeMilliseconds: Self.freshSnapshotReuseWindowMilliseconds)
            guard self.workController.isCurrent(workID) else { return }
            guard let raw = self.focusModel.snapshot.context, current.accepts(raw) else {
                self.restartTypingPrediction(reason: "Host publication diverged from the predicted edit.")
                return
            }
            if let expiry = current.expiration(in: raw), expiry <= ProcessInfo.processInfo.systemUptime {
                self.restartTypingPrediction(reason: "Prediction catch-up or host publication exceeded its time budget.")
            } else {
                self.scheduleTypingPredictionExpiry()
            }
        }
    }

    func restartTypingPrediction(reason: String) {
        let raw = focusModel.snapshot.context
        let awaitingPublication = typingPrediction.map { candidate in
            raw.map { candidate.accepts($0) && !candidate.isPublished(in: $0) } ?? false
        } ?? false
        let elapsed = typingPrediction?.lastInputAt.map {
            max(0, Int((ProcessInfo.processInfo.systemUptime - $0) * 1_000))
        } ?? 0
        logStage("typing-prediction-restarted", workID: currentWorkID,
                 generation: latestGenerationNumber, message: reason)
        cancelPredictionWork()
        clearSuggestion(clearDiagnostics: false)
        hideOverlay(reason: "Overlay hidden while refreshing a diverged typing prediction.")
        // Do not wait for a *second* AX change when the user's edit is already published.
        // Unpublished keys still cross the ordinary host-publish gate before a new request.
        if awaitingPublication {
            schedulePredictionAfterHostPublishDelay()
        } else {
            schedulePrediction(consumedDelayMilliseconds: elapsed)
        }
    }
}
