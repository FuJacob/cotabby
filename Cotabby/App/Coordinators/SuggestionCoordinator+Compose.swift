import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Compose Mode entry points for `SuggestionCoordinator`.
/// This is the deliberate two-step Tab flow: first Tab gathers context, generates a full draft,
/// and shows a preview; second Tab types the draft into the focused field. Autocomplete continues
/// to live in the sibling extension files and is untouched by this path.
///
/// State invariants this file protects:
/// - Only one Compose generation is in flight per `currentWorkID`; later Tabs cancel earlier work.
/// - The `ActiveComposeSession` is never accepted against a focused field whose process/identity
///   has changed since the draft was generated.
/// - Synthetic typing is rearmed against `InputSuppressionController` per chunk via the
///   `SuggestionInserter.typeDraft` contract.
extension SuggestionCoordinator {
    // MARK: - Tab Routing

    /// Routes a Tab/Escape/typing event while Compose Mode is active. The autocomplete pipeline
    /// is intentionally bypassed so typing in the field does not trigger inline generation.
    func handleComposeInputEvent(_ event: CapturedInputEvent) -> Bool {
        switch event.kind {
        case .acceptance, .fullAcceptance:
            if interactionState.activeComposeSession != nil {
                return acceptComposeDraft()
            }
            return startComposeGeneration()

        case .dismissal:
            cancelComposeWork(reason: "Compose cancelled by Escape.")
            return false

        case .navigation:
            // Arrow keys, page navigation, etc. — drop any in-flight draft because the field
            // context the user originally asked Tabby to draft against has moved.
            if interactionState.activeComposeSession != nil || isAnyComposeWorkInFlight {
                cancelComposeWork(reason: "Compose cancelled because the caret moved.")
            }
            return false

        case .textMutation, .shortcutMutation:
            // Typing or paste during preview invalidates the draft. Compose is "ask, review, type";
            // mid-stream edits mean the user has stopped reviewing.
            if interactionState.activeComposeSession != nil || isAnyComposeWorkInFlight {
                cancelComposeWork(reason: "Compose cancelled because the focused text changed.")
            }
            return false

        case .other:
            return false
        }
    }

    // MARK: - Generation

    /// First-Tab handler: kick off Compose generation against the current focused field.
    /// Returns `true` to consume the Tab so the host app does not receive it.
    @discardableResult
    func startComposeGeneration() -> Bool {
        guard permissionManager.inputMonitoringGranted else {
            return passTabThrough(reason: "Input Monitoring permission is required before Cotabby can draft a Compose response.")
        }

        let snapshot = focusModel.snapshot
        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            return passTabThrough(reason: snapshot.capability.summary)
        }

        if let disabledReason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: settingsSnapshot.isGloballyEnabled,
            disabledAppBundleIdentifiers: settingsSnapshot.disabledAppBundleIdentifiers,
            interactionMode: settingsSnapshot.selectedInteractionMode,
            inputMonitoringGranted: permissionManager.inputMonitoringGranted,
            screenRecordingGranted: permissionManager.screenRecordingGranted,
            focusSnapshot: snapshot
        ) {
            return passTabThrough(reason: disabledReason)
        }

        let context = interactionState.materializeContext(from: rawContext)

        // Reuse the debounced-work plumbing with a zero delay so cancellation and stale-work guards
        // are identical to the autocomplete path. Compose has no real debounce — Tab is explicit.
        let workID = workController.replaceDebouncedWork(delayMilliseconds: 0) { [weak self] workID in
            await self?.runComposeGeneration(for: context, workID: workID)
        }
        latestGenerationNumber = context.generation
        state = .generating
        logStage(
            "compose-generating",
            workID: workID,
            generation: context.generation,
            message: "Gathering Compose context for \(context.elementIdentifier) in \(context.applicationName)."
        )
        return true
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func runComposeGeneration(for context: FocusedInputContext, workID: UInt64) async {
        guard workController.isCurrent(workID) else { return }
        await awaitCachedGenerationContextResetIfNeeded()
        guard workController.isCurrent(workID) else { return }

        let collected: ComposeContextCollectionResult
        do {
            collected = try await composeContextCollector.collect(for: context)
        } catch is CancellationError {
            return
        } catch {
            guard workController.isCurrent(workID) else { return }
            await applyComposeFailure(error.localizedDescription, workID: workID)
            return
        }
        guard workController.isCurrent(workID) else { return }

        let clipboardContext: String? = {
            guard settingsSnapshot.isClipboardContextEnabled else { return nil }
            return clipboardContextProvider.currentContext()
        }()
        let visualContextSummary = visualContextCoordinator.excerpt(for: context)

        let buildResult = ComposeRequestFactory.buildRequest(
            context: context,
            settings: settingsSnapshot,
            configuration: configuration,
            surroundingContext: collected.text,
            clipboardContext: clipboardContext,
            visualContextSummary: visualContextSummary
        )
        latestPromptPreview = buildResult.promptPreview
        latestRawModelOutput = nil
        let request = buildResult.request

        workController.replaceGenerationWork(for: workID) { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.suggestionEngine.generateCompose(for: request)
                guard !Task.isCancelled, self.workController.isCurrent(workID) else { return }
                await self.applyComposeResult(result, workID: workID)
            } catch SuggestionClientError.cancelled {
                return
            } catch {
                guard self.workController.isCurrent(workID) else { return }
                await self.applyComposeFailure(error.localizedDescription, workID: workID)
            }
        }
    }

    /// Stale-result guard mirrors the autocomplete path: we re-read focus before showing anything,
    /// and bail if the field's generation or process no longer matches what we asked the model for.
    private func applyComposeResult(_ result: ComposeResult, workID: UInt64) async {
        guard workController.isCurrent(workID) else { return }

        focusModel.refreshNow()
        let snapshot = focusModel.snapshot

        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            disablePredictions(reason: snapshot.capability.summary)
            return
        }
        let liveContext = interactionState.materializeContext(from: rawContext)

        guard liveContext.generation == result.generation else {
            latestRawModelOutput = SuggestionDebugLogger.debugPreview(result.rawText)
            logStage(
                "compose-stale-drop",
                workID: workID,
                generation: result.generation,
                message: "Dropped stale Compose draft because live generation is \(liveContext.generation).",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            hideOverlay(reason: "Overlay hidden because the focused field changed before the draft was ready.")
            return
        }

        latestRawModelOutput = SuggestionDebugLogger.debugPreview(result.rawText)
        latestLatencyMilliseconds = Int(result.latency * 1000)
        latestGenerationNumber = liveContext.generation

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            interactionState.clearSuggestion()
            hideOverlay(reason: "Overlay hidden because Compose returned an empty draft.")
            state = .idle
            logStage(
                "compose-empty",
                workID: workID,
                generation: result.generation,
                message: "Compose draft was empty after normalization.",
                rawOutput: result.rawText,
                normalizedOutput: result.text
            )
            return
        }

        let session = interactionState.startComposeSession(
            fullText: result.text,
            liveContext: liveContext,
            latency: result.latency
        )
        latestSuggestionPreview = session.fullText
        latestFullSuggestionPreview = session.fullText
        latestRemainingSuggestionPreview = session.fullText
        latestAcceptedCharacterCount = 0
        latestRemainingCharacterCount = session.fullText.count
        state = .ready(text: session.fullText, latency: session.latency)

        presentComposePreview(
            text: session.fullText,
            at: liveContext.caretRect,
            inputFrameRect: liveContext.inputFrameRect,
            caretQuality: liveContext.caretQuality,
            observedCharWidth: liveContext.observedCharWidth,
            isRightToLeft: TextDirectionDetector.isRightToLeft(liveContext.precedingText)
        )
        logStage(
            "compose-ready",
            workID: workID,
            generation: result.generation,
            message: "Compose draft ready for review.",
            rawOutput: result.rawText,
            normalizedOutput: result.text
        )
    }

    private func applyComposeFailure(_ message: String, workID: UInt64) async {
        guard workController.isCurrent(workID) else { return }
        interactionState.clearSuggestion()
        hideOverlay(reason: "Overlay hidden because Compose generation failed.")
        state = .failed(message)
        logStage(
            "compose-failed",
            workID: workID,
            generation: latestGenerationNumber,
            message: message
        )
    }

    // MARK: - Acceptance

    /// Second-Tab handler: type the active Compose draft into the focused field via
    /// `SuggestionInserter.typeDraft`. Each chunk re-checks focus identity before posting.
    @discardableResult
    func acceptComposeDraft() -> Bool {
        guard let session = interactionState.activeComposeSession else {
            return passTabThrough(reason: "Key passed through because no Compose draft was ready.")
        }

        focusModel.refreshNow()
        let snapshot = focusModel.snapshot
        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            cancelComposeWork(reason: snapshot.capability.summary)
            return passTabThrough(reason: snapshot.capability.summary)
        }
        let liveContext = interactionState.materializeContext(from: rawContext)
        guard liveContext.identity == session.baseContext.identity,
              liveContext.processIdentifier == session.baseContext.processIdentifier else {
            cancelComposeWork(reason: "Compose cancelled because the focused field changed before typing began.")
            return passTabThrough(reason: "Key passed through because the focused field changed.")
        }
        guard liveContext.selection.length == 0 else {
            cancelComposeWork(reason: "Compose cancelled because text is selected.")
            return passTabThrough(reason: "Key passed through because text is selected.")
        }

        state = .typing
        recordAcceptedWords(from: session.fullText)
        logStage(
            "compose-accepting",
            workID: currentWorkID,
            generation: liveContext.generation,
            message: "Typing Compose draft (\(session.fullText.count) characters) into \(liveContext.applicationName).",
            normalizedOutput: session.fullText
        )

        let typingSession = session
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didType = await self.suggestionInserter.typeDraft(typingSession.fullText) { [weak self] in
                self?.composeTypingShouldContinue(matching: typingSession) ?? false
            }

            // The session may have already been cleared by a cancellation path (focus change,
            // mode change, Esc). If so, don't reset state again.
            guard let active = self.interactionState.activeComposeSession, active == typingSession else {
                return
            }

            if didType {
                self.interactionState.clearComposeSession(typingSession)
                self.hideOverlay(reason: "Overlay hidden after Compose draft was typed into the field.")
                self.state = .idle
                self.latestAcceptanceAction = "Compose draft typed into the field."
                self.logStage(
                    "compose-typed",
                    workID: self.currentWorkID,
                    generation: typingSession.baseContext.generation,
                    message: "Compose draft fully typed into the focused field.",
                    normalizedOutput: typingSession.fullText
                )
            } else {
                let message = self.suggestionInserter.lastErrorMessage
                    ?? "Compose typing stopped before the draft was complete."
                self.interactionState.clearComposeSession(typingSession)
                self.hideOverlay(reason: "Overlay hidden because Compose typing did not complete.")
                self.state = .failed(message)
                self.logStage(
                    "compose-type-aborted",
                    workID: self.currentWorkID,
                    generation: typingSession.baseContext.generation,
                    message: message,
                    normalizedOutput: typingSession.fullText
                )
            }
        }
        return true
    }

    /// Focus-identity guard checked between every synthetic key chunk. Bailing here lets the
    /// inserter stop posting mid-draft when the user switches apps or fields.
    private func composeTypingShouldContinue(matching session: ActiveComposeSession) -> Bool {
        guard let active = interactionState.activeComposeSession, active == session else {
            return false
        }
        let snapshot = focusModel.snapshot
        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            return false
        }
        return rawContext.processIdentifier == session.baseContext.processIdentifier
            && rawContext.elementIdentifier == session.baseContext.elementIdentifier
            && rawContext.focusChangeSequence == session.baseContext.focusChangeSequence
    }

    // MARK: - Cancellation

    /// Cancels any in-flight Compose work and clears the active session. Safe to call when nothing
    /// is in flight; the underlying controllers are no-op in that case.
    func cancelComposeWork(reason: String) {
        let hadActiveSession = interactionState.activeComposeSession != nil
        let hadInflightWork = isAnyComposeWorkInFlight
        guard hadActiveSession || hadInflightWork else { return }

        workController.cancelAll()
        if let session = interactionState.activeComposeSession {
            interactionState.clearComposeSession(session)
        } else {
            interactionState.clearSuggestion()
        }
        hideOverlay(reason: reason)
        state = .idle
        logStage(
            "compose-cancelled",
            workID: currentWorkID,
            generation: latestGenerationNumber,
            message: reason
        )
    }

    /// True when a Compose generation or typing task could still emit results. We treat any state
    /// other than `.idle` / `.disabled` as "could still emit" because the work controller only
    /// surfaces task identity, not status.
    var isAnyComposeWorkInFlight: Bool {
        switch state {
        case .generating, .typing:
            return true
        case .idle, .disabled, .debouncing, .ready, .failed:
            return false
        }
    }

    // MARK: - Overlay

    // swiftlint:disable function_parameter_count
    /// Sibling of `presentOverlay` for the multiline Compose preview surface.
    private func presentComposePreview(
        text: String,
        at caretRect: CGRect,
        inputFrameRect: CGRect?,
        caretQuality: CaretGeometryQuality,
        observedCharWidth: CGFloat?,
        isRightToLeft: Bool
    ) {
        let geometry = SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretQuality: caretQuality,
            observedCharWidth: observedCharWidth,
            isRightToLeft: isRightToLeft
        )
        if let message = overlayPresenter.presentComposePreview(
            text: text,
            geometry: geometry,
            previousState: overlayState
        ) {
            latestOverlayMessage = message
        }
    }
    // swiftlint:enable function_parameter_count
}
