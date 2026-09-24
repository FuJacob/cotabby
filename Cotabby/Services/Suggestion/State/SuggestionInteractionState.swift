import Foundation

/// File overview:
/// Owns the mutable interaction state that sits between Accessibility snapshots and a live
/// suggestion session. This includes the buffered focused-input context, the active suggestion
/// session, and the AX-lag sentinels used after partial acceptance or matching typed input.
///
/// The architectural lesson is that `SuggestionCoordinator` should orchestrate state transitions,
/// not store every mutable implementation detail itself. This type becomes the home for that
/// lower-level session/context state.
@MainActor
final class SuggestionInteractionState {
    private let contextBuffer: ContextBuffer

    private(set) var activeSession: ActiveSuggestionSession?
    private(set) var pendingInsertionConsumedCount: Int?
    /// Typed input only tolerates an older matching prefix. It must not inherit the broader
    /// synthetic-insertion tolerance for temporarily inconsistent AX prefix/suffix slices.
    private var pendingTypedConsumedRange: Range<Int>?

    init(contextBuffer: ContextBuffer? = nil) {
        // Default argument evaluation happens before entering the actor-isolated initializer body,
        // so we build the default buffer here instead of in the signature.
        self.contextBuffer = contextBuffer ?? ContextBuffer()
    }

    var currentContext: FocusedInputContext? {
        contextBuffer.currentContext
    }

    /// Exposes the higher-level meaning of `pendingInsertionConsumedCount` without leaking the
    /// sentinel's storage detail to the coordinator. When this is true, accepted or directly typed
    /// suggestion text has advanced the ghost and Accessibility has not published it yet.
    var isAwaitingPostInsertionSync: Bool {
        pendingInsertionConsumedCount != nil || pendingTypedConsumedRange != nil
    }

    func materializeContext(from snapshot: FocusedInputSnapshot) -> FocusedInputContext {
        contextBuffer.materialize(from: snapshot)
    }

    func clearSuggestion() {
        activeSession = nil
        pendingInsertionConsumedCount = nil
        pendingTypedConsumedRange = nil
    }

    func resetAll() {
        contextBuffer.clear()
        clearSuggestion()
    }

    func startSession(
        fullText: String,
        liveContext: FocusedInputContext,
        latency: TimeInterval,
        kind: SuggestionKind = .continuation
    ) -> ActiveSuggestionSession {
        let session = ActiveSuggestionSession(
            baseContext: liveContext,
            fullText: fullText,
            latency: latency,
            kind: kind
        )
        activeSession = session
        pendingInsertionConsumedCount = nil
        pendingTypedConsumedRange = nil
        return session
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
            pendingInsertionConsumedCount: pendingInsertionConsumedCount,
            pendingTypedConsumedRange: pendingTypedConsumedRange
        ) {
        case let .valid(reconciledSession, advancement, nextPendingInsertionConsumedCount):
            self.activeSession = reconciledSession
            pendingInsertionConsumedCount = nextPendingInsertionConsumedCount
            clearPublishedTypedInput(in: liveContext, session: reconciledSession)
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
    func prepareAcceptance(
        from snapshot: FocusedInputSnapshot,
        overlayState: OverlayState,
        granularity: AcceptanceGranularity,
        autoAcceptTrailingPunctuation: Bool = true
    ) -> SuggestionAcceptancePreparation {
        let validated = validateSessionForAcceptance(from: snapshot, overlayState: overlayState)
        guard let (liveContext, session) = validated.session else {
            return .invalid(validated.failureReason ?? "Key passed through.")
        }

        let chunk: String
        switch granularity {
        case .word:
            chunk = SuggestionSessionReconciler.nextAcceptanceChunk(
                from: session.remainingText,
                autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation
            )
        case .phrase:
            chunk = SuggestionSessionReconciler.nextAcceptancePhrase(
                from: session.remainingText,
                autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation
            )
        }

        guard !chunk.isEmpty else {
            return .invalid("Key passed through because no remaining suggestion chunk was available.")
        }
        return .ready(liveContext: liveContext, session: session, acceptedChunk: chunk)
    }

    func prepareFullAcceptance(
        from snapshot: FocusedInputSnapshot,
        overlayState: OverlayState
    ) -> SuggestionAcceptancePreparation {
        let validated = validateSessionForAcceptance(from: snapshot, overlayState: overlayState)
        guard let (liveContext, session) = validated.session else {
            return .invalid(validated.failureReason ?? "Key passed through.")
        }

        let chunk = session.remainingText
        guard !chunk.isEmpty else {
            return .invalid("Key passed through because no remaining suggestion text was available.")
        }
        return .ready(liveContext: liveContext, session: session, acceptedChunk: chunk)
    }

    /// Shared validation for both word-by-word and full acceptance.
    private struct SessionValidation {
        let session: (FocusedInputContext, ActiveSuggestionSession)?
        let failureReason: String?
    }

    private func validateSessionForAcceptance(
        from snapshot: FocusedInputSnapshot,
        overlayState: OverlayState
    ) -> SessionValidation {
        guard let activeSession else {
            return SessionValidation(session: nil, failureReason: "Key passed through because no valid suggestion was ready.")
        }

        guard snapshot.selection.length == 0 else {
            return SessionValidation(session: nil, failureReason: "Key passed through because text is currently selected.")
        }

        guard SuggestionSessionReconciler.overlayAllowsAcceptance(
            of: activeSession.remainingText,
            overlayState: overlayState
        ) else {
            return SessionValidation(
                session: nil,
                failureReason: "Key passed through because no visible ghost text matched the ready suggestion."
            )
        }

        let liveContext = contextBuffer.materialize(from: snapshot)
        let sessionForAcceptance: ActiveSuggestionSession

        if overlayState.isVisible {
            switch SuggestionSessionReconciler.reconcile(
                session: activeSession,
                with: liveContext,
                pendingInsertionConsumedCount: pendingInsertionConsumedCount,
                pendingTypedConsumedRange: pendingTypedConsumedRange
            ) {
            case .invalid(let reason):
                return SessionValidation(session: nil, failureReason: reason)

            case let .valid(reconciledSession, _, nextPendingInsertionConsumedCount):
                self.activeSession = reconciledSession
                pendingInsertionConsumedCount = nextPendingInsertionConsumedCount
                clearPublishedTypedInput(in: liveContext, session: reconciledSession)
                sessionForAcceptance = reconciledSession
            }
        } else {
            guard liveContext.processIdentifier == activeSession.baseContext.processIdentifier else {
                return SessionValidation(session: nil, failureReason: "Key passed through because the focused field changed.")
            }

            sessionForAcceptance = activeSession
        }

        guard !sessionForAcceptance.isExhausted else {
            return SessionValidation(
                session: nil,
                failureReason: "Key passed through because no remaining suggestion text was available."
            )
        }

        return SessionValidation(session: (liveContext, sessionForAcceptance), failureReason: nil)
    }

    /// Advances the active session after a successful insertion and updates the AX-lag sentinel.
    func commitAcceptedChunk(
        _ acceptedChunk: String,
        liveContext: FocusedInputContext,
        session: ActiveSuggestionSession
    ) -> SuggestionAcceptedChunkProgress {
        let advancedSession = session.advancing(by: acceptedChunk.count)
        pendingInsertionConsumedCount = advancedSession.consumedCharacterCount
        // The new synthetic insert now owns publication of the entire consumed prefix, including
        // any matching characters typed immediately before this accept.
        pendingTypedConsumedRange = nil

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
        if pendingInsertionConsumedCount != nil {
            // A matching key can arrive before a preceding Tab insert publishes. Keep that existing
            // insertion window aimed at the latest consumed prefix instead of disabling it merely
            // because the user typed one more expected character.
            pendingInsertionConsumedCount = advancedSession.consumedCharacterCount
        } else {
            let firstUnpublishedCount = pendingTypedConsumedRange?.lowerBound ?? activeSession.consumedCharacterCount
            pendingTypedConsumedRange = firstUnpublishedCount..<advancedSession.consumedCharacterCount
        }
        return advancedSession
    }

    /// Retires typed-input tolerance as soon as AX contains the expected prefix. Later deletion of
    /// those letters is then a real edit again, not an indefinitely tolerated publication delay.
    private func clearPublishedTypedInput(in context: FocusedInputContext, session: ActiveSuggestionSession) {
        guard let count = pendingTypedConsumedRange?.upperBound else { return }
        let expectedPrefix = session.baseContext.precedingText + String(session.fullText.prefix(count))
        if context.precedingText.hasPrefix(expectedPrefix) {
            pendingTypedConsumedRange = nil
        }
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
