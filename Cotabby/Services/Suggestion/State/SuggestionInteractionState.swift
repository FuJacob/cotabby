import Foundation

/// File overview:
/// Owns the mutable interaction state that sits between Accessibility snapshots and a live
/// suggestion session. This includes the buffered focused-input context, the active suggestion
/// session, and how far the host's published text trails that session.
///
/// The architectural lesson is that `SuggestionCoordinator` should orchestrate state transitions,
/// not store every mutable implementation detail itself. This type becomes the home for that
/// lower-level session/context state.
@MainActor
final class SuggestionInteractionState {
    private let contextBuffer: ContextBuffer

    private(set) var activeSession: ActiveSuggestionSession?
    /// Meaningful only while a session is active; every path that drops or replaces the session
    /// settles it.
    private(set) var publicationLag: HostPublicationLag = .settled

    init(contextBuffer: ContextBuffer? = nil) {
        // Default argument evaluation happens before entering the actor-isolated initializer body,
        // so we build the default buffer here instead of in the signature.
        self.contextBuffer = contextBuffer ?? ContextBuffer()
    }

    var currentContext: FocusedInputContext? {
        contextBuffer.currentContext
    }

    /// True while accepted or directly typed suggestion text has advanced the ghost and
    /// Accessibility has not published it yet.
    var isAwaitingPostInsertionSync: Bool {
        publicationLag != .settled
    }

    func materializeContext(from snapshot: FocusedInputSnapshot) -> FocusedInputContext {
        contextBuffer.materialize(from: snapshot)
    }

    func clearSuggestion() {
        activeSession = nil
        publicationLag = .settled
    }

    func resetAll() {
        contextBuffer.clear()
        clearSuggestion()
    }

    func startSession(
        fullText: String,
        initialVisibleCharacterCount: Int? = nil,
        showFollowingWords: Bool = true,
        liveContext: FocusedInputContext,
        latency: TimeInterval,
        kind: SuggestionKind = .continuation
    ) -> ActiveSuggestionSession {
        let session = ActiveSuggestionSession(
            baseContext: liveContext,
            fullText: fullText,
            initialVisibleCharacterCount: initialVisibleCharacterCount,
            showFollowingWords: showFollowingWords,
            latency: latency,
            kind: kind
        )
        activeSession = session
        publicationLag = .settled
        return session
    }

    /// Adds a monotonic prediction extension without restarting an interaction already in flight.
    /// The coordinator captures the expected session before async lookahead; equality rejects an
    /// answer for an old anchor or consumed position. The existing publication lag remains
    /// valid because no characters before the extended suffix change.
    func extendPrediction(
        fullText: String,
        expectedSession: ActiveSuggestionSession
    ) -> ActiveSuggestionSession? {
        guard let activeSession,
              activeSession == expectedSession,
              let extendedSession = activeSession.extendingPrediction(to: fullText) else {
            return nil
        }
        self.activeSession = extendedSession
        return extendedSession
    }

    /// A conversation switch invalidates work even when both composers contain identical text.
    /// The session key tolerates AX wrapper churn while retaining the tracker's navigation signal.
    func hasFocusedElementChanged(comparedTo focusedContext: FocusedInputSnapshot) -> Bool {
        guard let currentContext = currentContext ?? activeSession?.baseContext else {
            return false
        }

        return !focusedContext.sessionIdentity.continues(currentContext.sessionIdentity)
    }

    /// Reconciles the currently active session against the latest AX snapshot and stores the
    /// updated session and publication lag when reconciliation succeeds.
    func reconcileActiveSession(
        with snapshot: FocusedInputSnapshot
    ) -> SuggestionStoredSessionReconciliation? {
        guard let activeSession else {
            return nil
        }

        let liveContext = contextBuffer.materialize(from: snapshot)
        switch SuggestionSessionReconciler.reconcile(session: activeSession, with: liveContext, lag: publicationLag) {
        case let .valid(reconciledSession, advancement, nextLag):
            self.activeSession = reconciledSession
            publicationLag = nextLag
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
    ///
    /// `granularity` selects between word-by-word and phrase-by-phrase acceptance. Whole-
    /// suggestion acceptance is the dedicated full-accept key's responsibility and is routed
    /// through `prepareFullAcceptance`, so the granularity enum has no case for it here.
    ///
    /// `heldPresentationText` is the overlay controller's not-yet-painted presentation, if any
    /// (see `SuggestionSessionReconciler.overlayAllowsAcceptance`). Defaulted so callers that have
    /// no deferred presenter keep the strict "visible text must equal the tail" rule.
    func prepareAcceptance(
        from snapshot: FocusedInputSnapshot,
        overlayState: OverlayState,
        heldPresentationText: String? = nil,
        granularity: AcceptanceGranularity,
        autoAcceptTrailingPunctuation: Bool = true
    ) -> SuggestionAcceptancePreparation {
        prepare(
            from: snapshot,
            overlayState: overlayState,
            heldPresentationText: heldPresentationText,
            emptyChunkReason: "Key passed through because no remaining suggestion chunk was available."
        ) { session in
            switch granularity {
            case .word:
                return SuggestionSessionReconciler.nextAcceptanceChunk(
                    from: session.remainingText,
                    autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation
                )
            case .phrase:
                return SuggestionSessionReconciler.nextAcceptancePhrase(
                    from: session.remainingText,
                    autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation
                )
            }
        }
    }

    func prepareFullAcceptance(
        from snapshot: FocusedInputSnapshot,
        overlayState: OverlayState,
        heldPresentationText: String? = nil
    ) -> SuggestionAcceptancePreparation {
        prepare(
            from: snapshot,
            overlayState: overlayState,
            heldPresentationText: heldPresentationText,
            emptyChunkReason: "Key passed through because no remaining suggestion text was available.",
            chunk: \.remainingText
        )
    }

    /// Validates the session once, then lets the caller choose how much of its visible tail this
    /// key takes. Both acceptance keys share the validation so neither can commit text the other
    /// would have refused.
    private func prepare(
        from snapshot: FocusedInputSnapshot,
        overlayState: OverlayState,
        heldPresentationText: String?,
        emptyChunkReason: String,
        chunk: (ActiveSuggestionSession) -> String
    ) -> SuggestionAcceptancePreparation {
        switch validateSessionForAcceptance(
            from: snapshot, overlayState: overlayState, heldPresentationText: heldPresentationText
        ) {
        case let .rejected(reason):
            return .invalid(reason)
        case let .accepted(liveContext, session):
            let acceptedChunk = chunk(session)
            guard !acceptedChunk.isEmpty else {
                return .invalid(emptyChunkReason)
            }
            return .ready(liveContext: liveContext, session: session, acceptedChunk: acceptedChunk)
        }
    }

    /// Outcome of the validation shared by word-by-word and full acceptance.
    private enum SessionValidation {
        case accepted(liveContext: FocusedInputContext, session: ActiveSuggestionSession)
        case rejected(String)
    }

    private func validateSessionForAcceptance(
        from snapshot: FocusedInputSnapshot,
        overlayState: OverlayState,
        heldPresentationText: String?
    ) -> SessionValidation {
        guard let activeSession else {
            return .rejected("Key passed through because no valid suggestion was ready.")
        }

        guard snapshot.selection.length == 0 else {
            return .rejected("Key passed through because text is currently selected.")
        }

        guard SuggestionSessionReconciler.overlayAllowsAcceptance(
            of: activeSession.remainingText,
            overlayState: overlayState,
            heldPresentationText: heldPresentationText
        ) else {
            return .rejected(
                "Key passed through because no visible ghost text matched the ready suggestion."
            )
        }

        let liveContext = contextBuffer.materialize(from: snapshot)
        let sessionForAcceptance: ActiveSuggestionSession

        if overlayState.isVisible {
            switch SuggestionSessionReconciler.reconcile(session: activeSession, with: liveContext, lag: publicationLag) {
            case .invalid(let reason):
                return .rejected(reason)

            case let .valid(reconciledSession, _, nextLag):
                self.activeSession = reconciledSession
                publicationLag = nextLag
                sessionForAcceptance = reconciledSession
            }
        } else {
            guard liveContext.sessionIdentity.continues(activeSession.baseContext.sessionIdentity) else {
                return .rejected("Key passed through because the focused field changed.")
            }

            sessionForAcceptance = activeSession
        }

        guard !sessionForAcceptance.isExhausted else {
            return .rejected(
                "Key passed through because no remaining suggestion text was available."
            )
        }

        // AX may reveal a just-typed word before its key event has advanced the ghost. Reconciliation
        // can then cross a presentation boundary and expose a new buffered word. That text was not
        // in the ghost the user accepted, so this key must not silently commit it. A normal advance
        // within the same visible offer remains acceptable because its tail is still that offer's
        // exact suffix.
        let reconciledAdvance = sessionForAcceptance.consumedCharacterCount - activeSession.consumedCharacterCount
        let previouslyOfferedTail = String(activeSession.remainingText.dropFirst(max(reconciledAdvance, 0)))
        guard sessionForAcceptance.remainingText == previouslyOfferedTail else {
            return .rejected(
                "Key passed through because the next buffered word has not been shown yet."
            )
        }

        return .accepted(liveContext: liveContext, session: sessionForAcceptance)
    }

    /// Advances the active session after a successful insertion and opens the publication window
    /// for it.
    func commitAcceptedChunk(
        _ acceptedChunk: String,
        liveContext: FocusedInputContext,
        session: ActiveSuggestionSession
    ) -> SuggestionAcceptedChunkProgress {
        let advancedSession = session.advancing(by: acceptedChunk.count)

        if advancedSession.isExhausted {
            publicationLag = .settled
            activeSession = nil
            return .exhausted(generation: liveContext.generation)
        }

        // The new synthetic insert now owns publication of the entire consumed prefix, including
        // any matching characters typed immediately before this accept.
        publicationLag = .awaitingSyntheticInsert(consumedCount: advancedSession.consumedCharacterCount)
        activeSession = advancedSession
        return .advanced(session: advancedSession, generation: liveContext.generation)
    }

    /// Advances the stored session when the user typed the next expected characters directly.
    ///
    /// The advance comes from the key event, which lands before the host publishes the character
    /// through Accessibility. The next focus poll can therefore still show the field WITHOUT the
    /// character the session already counts as consumed, and the reconciler would read that as
    /// the user undoing part of the suggestion (measured in the Claude composer, 2026-09-10: the
    /// ghost vanished right after "the" was typed through and came back on the next keystroke).
    /// The publication lag covers this the way it covers a Tab insert: the reconciler tolerates a
    /// shorter live text until it catches up, then settles.
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
        publicationLag = publicationLag.afterTypedAdvance(from: activeSession, to: advancedSession)
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
