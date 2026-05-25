import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Compose Mode entry points for `SuggestionCoordinator`.
///
/// Interaction model (single-Tab streaming):
/// - First Tab → gather AX context, build request, open a streaming generation against llama.
///   Each sampled piece is typed straight into the focused field via `SuggestionInserter.insert`.
/// - Escape, focus change, app/global disable, or the user typing → cancel the stream. Already-
///   typed characters stay in the field; the cancellation simply stops the next piece from
///   landing.
/// - Subsequent Tabs while streaming are absorbed so the user does not pile a second draft onto
///   the first.
extension SuggestionCoordinator {
    // MARK: - Tab Routing

    /// Routes a Tab/Escape/typing event while Compose Mode is active. The autocomplete pipeline
    /// is intentionally bypassed so typing in the field does not trigger inline generation.
    func handleComposeInputEvent(_ event: CapturedInputEvent) -> Bool {
        switch event.kind {
        case .acceptance, .fullAcceptance:
            // Already streaming? Swallow the Tab so it does not start a second stream and does
            // not reach the host app while we are typing into it.
            if interactionState.activeComposeSession != nil || isAnyComposeWorkInFlight {
                return true
            }
            return startComposeGeneration()

        case .dismissal:
            cancelComposeWork(reason: "Compose cancelled by Escape.")
            return false

        case .navigation:
            // Arrow keys, page navigation, etc. — drop in-flight streams because the field the
            // user originally asked Tabby to draft into has moved.
            if interactionState.activeComposeSession != nil || isAnyComposeWorkInFlight {
                cancelComposeWork(reason: "Compose cancelled because the caret moved.")
            }
            return false

        case .textMutation, .shortcutMutation:
            // Real user typing during streaming → stop. Tabby's own synthetic key events are
            // absorbed by `InputSuppressionController` before they reach this handler, so the
            // stream's own characters never trigger this path.
            if interactionState.activeComposeSession != nil || isAnyComposeWorkInFlight {
                cancelComposeWork(reason: "Compose cancelled because the focused text changed.")
            }
            return false

        case .other:
            return false
        }
    }

    // MARK: - Generation

    /// Streams a Compose draft into the currently focused field. Returns `true` to consume the Tab.
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
            await self?.runComposeStreaming(for: context, workID: workID)
        }
        latestGenerationNumber = context.generation
        latestRawModelOutput = nil
        state = .generating
        logStage(
            "compose-streaming-start",
            workID: workID,
            generation: context.generation,
            message: "Gathering Compose context for \(context.elementIdentifier) in \(context.applicationName)."
        )
        return true
    }

    private func runComposeStreaming(for context: FocusedInputContext, workID: UInt64) async {
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
        let request = buildResult.request

        // The active session represents "we are streaming into this field". The full text is
        // appended to as pieces arrive so logs and diagnostics can describe what was typed.
        let initialSession = interactionState.startComposeSession(
            fullText: "",
            liveContext: context,
            latency: 0
        )
        state = .typing
        logStage(
            "compose-streaming-begin",
            workID: workID,
            generation: context.generation,
            message: "Streaming Compose draft into \(context.applicationName).",
            prompt: buildResult.promptPreview
        )

        workController.replaceGenerationWork(for: workID) { [weak self] in
            guard let self else { return }
            await self.consumeComposeStream(
                request: request,
                workID: workID,
                initialSession: initialSession
            )
        }
    }

    private func consumeComposeStream(
        request: ComposeRequest,
        workID: UInt64,
        initialSession: ActiveComposeSession
    ) async {
        let startTime = Date()
        var accumulatedText = ""
        var session = initialSession

        do {
            let stream = try await suggestionEngine.generateComposeStreaming(for: request)
            for try await piece in stream {
                guard !Task.isCancelled, workController.isCurrent(workID) else { break }
                guard composeStreamShouldContinue(matching: session) else { break }
                guard !piece.isEmpty else { continue }

                accumulatedText += piece
                latestRawModelOutput = SuggestionDebugLogger.debugPreview(accumulatedText)
                _ = suggestionInserter.insert(piece)
                session = interactionState.updateComposeSession(
                    session,
                    fullText: accumulatedText,
                    latency: Date().timeIntervalSince(startTime)
                ) ?? session

                // Yield once per piece so cancellation tasks queued on the main actor (focus
                // changes, Esc) can run between samples instead of getting starved by the loop.
                await Task.yield()
            }
        } catch is CancellationError {
            // Treat cancellation as a normal stop — partial text stays in the field.
            await finishComposeStream(
                accumulated: accumulatedText,
                latency: Date().timeIntervalSince(startTime),
                workID: workID,
                session: session,
                outcome: ComposeStreamOutcome(
                    stage: "compose-streaming-cancelled",
                    stageMessage: "Compose stream cancelled."
                )
            )
            return
        } catch {
            await applyComposeFailure(error.localizedDescription, workID: workID)
            return
        }

        await finishComposeStream(
            accumulated: accumulatedText,
            latency: Date().timeIntervalSince(startTime),
            workID: workID,
            session: session,
            outcome: ComposeStreamOutcome(
                stage: "compose-streaming-done",
                stageMessage: "Compose stream finished."
            )
        )
    }

    private struct ComposeStreamOutcome {
        let stage: String
        let stageMessage: String
    }

    private func finishComposeStream(
        accumulated: String,
        latency: TimeInterval,
        workID: UInt64,
        session: ActiveComposeSession,
        outcome: ComposeStreamOutcome
    ) async {
        guard workController.isCurrent(workID) else { return }

        latestLatencyMilliseconds = Int(latency * 1000)
        latestRawModelOutput = SuggestionDebugLogger.debugPreview(accumulated)
        latestAcceptanceAction = accumulated.isEmpty
            ? "Compose stream produced no text."
            : "Compose draft streamed into the field."

        if interactionState.activeComposeSession == session {
            interactionState.clearComposeSession(session)
        }
        hideOverlay(reason: outcome.stageMessage)
        state = .idle
        logStage(
            outcome.stage,
            workID: workID,
            generation: session.baseContext.generation,
            message: outcome.stageMessage,
            normalizedOutput: accumulated
        )
    }

    private func applyComposeFailure(_ message: String, workID: UInt64) async {
        guard workController.isCurrent(workID) else { return }
        if let session = interactionState.activeComposeSession {
            interactionState.clearComposeSession(session)
        } else {
            interactionState.clearSuggestion()
        }
        hideOverlay(reason: "Overlay hidden because Compose generation failed.")
        state = .failed(message)
        logStage(
            "compose-failed",
            workID: workID,
            generation: latestGenerationNumber,
            message: message
        )
    }

    /// Focus-identity guard checked before posting each streamed piece. Returns false when the
    /// session has been cleared or the focused field has changed, which halts the for-await loop.
    private func composeStreamShouldContinue(matching session: ActiveComposeSession) -> Bool {
        guard interactionState.activeComposeSession == session else { return false }
        let snapshot = focusModel.snapshot
        guard case .supported = snapshot.capability, let rawContext = snapshot.context else {
            return false
        }
        return rawContext.processIdentifier == session.baseContext.processIdentifier
            && rawContext.elementIdentifier == session.baseContext.elementIdentifier
            && rawContext.focusChangeSequence == session.baseContext.focusChangeSequence
    }

    // MARK: - Cancellation

    /// Cancels any in-flight Compose work and clears the active session. Already-typed characters
    /// remain in the focused field — Compose's stream is fire-and-forget per piece, so we cannot
    /// (and should not) try to undo what the host app has already accepted.
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

    /// True when a Compose generation or streaming task could still emit output.
    var isAnyComposeWorkInFlight: Bool {
        switch state {
        case .generating, .typing:
            return true
        case .idle, .disabled, .debouncing, .ready, .failed:
            return false
        }
    }
}
