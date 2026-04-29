import Foundation

/// File overview:
/// Owns the mutable interaction state that sits between Accessibility snapshots and a live
/// suggestion session. This includes the buffered focused-input context, the active suggestion
/// session, and the AX-lag sentinel used after partial Tab acceptance.
///
/// The architectural lesson is that `SuggestionCoordinator` should orchestrate state transitions,
/// not store every mutable implementation detail itself. This type becomes the home for that
/// lower-level session/context state.
@MainActor
final class SuggestionInteractionState {
    private let contextBuffer: ContextBuffer

    private(set) var activeSession: ActiveSuggestionSession?
    private(set) var pendingInsertionConsumedCount: Int?

    init(contextBuffer: ContextBuffer? = nil) {
        // Default argument evaluation happens before entering the actor-isolated initializer body,
        // so we build the default buffer here instead of in the signature.
        self.contextBuffer = contextBuffer ?? ContextBuffer()
    }

    var currentContext: FocusedInputContext? {
        contextBuffer.currentContext
    }

    /// Exposes the higher-level meaning of `pendingInsertionConsumedCount` without leaking the
    /// sentinel's storage detail to the coordinator. When this is true, Tabby has already inserted
    /// suggestion text and is waiting for Accessibility to publish a matching live snapshot.
    var isAwaitingPostInsertionSync: Bool {
        pendingInsertionConsumedCount != nil
    }

    func materializeContext(from snapshot: FocusedInputSnapshot) -> FocusedInputContext {
        contextBuffer.materialize(from: snapshot)
    }

    func clearContext() {
        contextBuffer.clear()
    }

    func clearSuggestion() {
        activeSession = nil
        pendingInsertionConsumedCount = nil
    }

    func resetAll() {
        contextBuffer.clear()
        clearSuggestion()
    }

    func startSession(
        fullText: String,
        liveContext: FocusedInputContext,
        latency: TimeInterval,
        isStreaming: Bool = false
    ) -> ActiveSuggestionSession {
        let session = ActiveSuggestionSession(
            baseContext: liveContext,
            fullText: fullText,
            latency: latency,
            isStreaming: isStreaming
        )
        activeSession = session
        pendingInsertionConsumedCount = nil
        return session
    }

    /// Extends the current session with a newer stable prefix from a streaming backend.
    /// The accepted prefix is immutable: if new streamed text no longer starts with what the user
    /// already accepted, the stream belongs to stale model state and must be discarded.
    func updateStreamingSession(
        stableText: String,
        latency: TimeInterval,
        isStreaming: Bool
    ) -> ActiveSuggestionSession? {
        guard let activeSession else {
            return nil
        }

        guard stableText.hasPrefix(activeSession.acceptedText) else {
            return nil
        }

        let updatedSession = activeSession.withStableText(
            stableText,
            isStreaming: isStreaming,
            latency: latency
        )
        self.activeSession = updatedSession
        return updatedSession
    }

    /// Uses process-level identity instead of AX element identity because Chrome recycles
    /// AX node tokens between polls, making `CFHash`-based `elementIdentifier` unstable.
    /// Intra-process field switches are caught downstream by content/text guards.
    func hasFocusedElementChanged(comparedTo focusedContext: FocusedInputSnapshot) -> Bool {
        guard let currentContext else {
            return false
        }

        return currentContext.processIdentifier != focusedContext.processIdentifier
    }

    /// Reconciles the currently active session against the latest AX snapshot and stores the
    /// updated session/sentinel when reconciliation succeeds.
    func reconcileActiveSession(
        with snapshot: FocusedInputSnapshot
    ) -> SuggestionStoredSessionReconciliation? {
        guard let activeSession else {
            return nil
        }

        let liveContext = contextBuffer.materialize(from: snapshot)
        switch SuggestionSessionReconciler.reconcile(
            session: activeSession,
            with: liveContext,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount
        ) {
        case let .valid(reconciledSession, advancement, nextPendingInsertionConsumedCount):
            self.activeSession = reconciledSession
            pendingInsertionConsumedCount = nextPendingInsertionConsumedCount
            return .valid(
                liveContext: liveContext,
                session: reconciledSession,
                advancement: advancement
            )

        case let .invalid(reason):
            return .invalid(reason)
        }
    }

    /// Validates whether the current stored session can be accepted from the latest live AX state.
    /// The returned value gives the coordinator the exact chunk to insert and the context it should
    /// use for diagnostics and overlay updates.
    func prepareAcceptance(
        from snapshot: FocusedInputSnapshot,
        overlayState: OverlayState
    ) -> SuggestionAcceptancePreparation {
        guard let activeSession else {
            return .invalid("Tab passed through because no valid suggestion was ready.")
        }

        guard snapshot.selection.length == 0 else {
            return .invalid("Tab passed through because text is currently selected.")
        }

        guard SuggestionSessionReconciler.overlayAllowsAcceptance(
            of: activeSession.remainingText,
            overlayState: overlayState
        ) else {
            return .invalid("Tab passed through because no visible ghost text matched the ready suggestion.")
        }

        let liveContext = contextBuffer.materialize(from: snapshot)
        let sessionForAcceptance: ActiveSuggestionSession

        if overlayState.isVisible {
            // A visible overlay means AX has already caught up to the current caret/text state,
            // so we can insist that live editor state and session state agree before accepting.
            switch SuggestionSessionReconciler.reconcile(
                session: activeSession,
                with: liveContext,
                pendingInsertionConsumedCount: pendingInsertionConsumedCount
            ) {
            case .invalid(let reason):
                return .invalid(reason)

            case let .valid(reconciledSession, _, nextPendingInsertionConsumedCount):
                self.activeSession = reconciledSession
                pendingInsertionConsumedCount = nextPendingInsertionConsumedCount
                sessionForAcceptance = reconciledSession
            }
        } else {
            // We intentionally allow acceptance while the overlay is temporarily hidden.
            // That hidden state usually means "waiting for host app caret sync" after a prior
            // partial acceptance, not "there is no active suggestion anymore."
            guard liveContext.processIdentifier == activeSession.baseContext.processIdentifier else {
                return .invalid("Tab passed through because the focused field changed.")
            }

            sessionForAcceptance = activeSession
        }

        guard !sessionForAcceptance.isExhausted else {
            return .invalid("Tab passed through because no remaining suggestion text was available.")
        }

        let acceptedChunk = SuggestionSessionReconciler.nextAcceptanceChunk(from: sessionForAcceptance.remainingText)
        guard !acceptedChunk.isEmpty else {
            return .invalid("Tab passed through because no remaining suggestion chunk was available.")
        }

        return .ready(
            liveContext: liveContext,
            session: sessionForAcceptance,
            acceptedChunk: acceptedChunk
        )
    }

    /// Advances the active session after a successful insertion and updates the AX-lag sentinel.
    func commitAcceptedChunk(
        _ acceptedChunk: String,
        liveContext: FocusedInputContext,
        session: ActiveSuggestionSession
    ) -> SuggestionAcceptedChunkProgress {
        let advancedSession = session.advancing(by: acceptedChunk.count)
        pendingInsertionConsumedCount = advancedSession.consumedCharacterCount

        if advancedSession.isExhausted {
            pendingInsertionConsumedCount = nil
            activeSession = nil
            return .exhausted(generation: liveContext.generation)
        }

        activeSession = advancedSession
        return .advanced(session: advancedSession, generation: liveContext.generation)
    }

    /// Advances the stored session when the user typed the next expected characters directly.
    func advanceIfTypedCharactersMatch(
        _ typedCharacters: String,
        expectedSession: ActiveSuggestionSession
    ) -> ActiveSuggestionSession? {
        guard let activeSession,
              activeSession == expectedSession,
              let advancedSession = SuggestionSessionReconciler.advanceIfTypedCharactersMatch(
                  typedCharacters,
                  session: activeSession
              )
        else {
            return nil
        }

        self.activeSession = advancedSession
        return advancedSession
    }
}

/// Wraps reconciliation results with the live buffered context the coordinator needs for UI updates.
enum SuggestionStoredSessionReconciliation {
    case valid(
        liveContext: FocusedInputContext,
        session: ActiveSuggestionSession,
        advancement: SuggestionSessionAdvancement?
    )
    case invalid(String)
}

/// Encodes whether the current stored session can be accepted from the latest AX snapshot.
enum SuggestionAcceptancePreparation {
    case ready(
        liveContext: FocusedInputContext,
        session: ActiveSuggestionSession,
        acceptedChunk: String
    )
    case invalid(String)
}

/// Describes how the stored session changed after the accepted text was successfully inserted.
enum SuggestionAcceptedChunkProgress {
    case advanced(session: ActiveSuggestionSession, generation: UInt64)
    case exhausted(generation: UInt64)
}
