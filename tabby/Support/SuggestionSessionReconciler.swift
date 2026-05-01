import Foundation

/// File overview:
/// Owns the pure interaction rules for an active suggestion session. This includes how live editor
/// state is reconciled against a buffered suggestion tail and how acceptance chunks are chosen.
///
/// Architectural role:
/// `SuggestionCoordinator` owns mutable session state. This file owns the deterministic rules for
/// transforming that state when new editor input arrives.
struct SuggestionSessionAdvancement: Equatable, Sendable {
    let stage: String
    let message: String
    let actionSummary: String
    let exhaustionStage: String
    let exhaustionMessage: String
}

enum SuggestionSessionReconciliation: Equatable, Sendable {
    /// `nextPendingInsertionConsumedCount` carries the updated AX-lag sentinel back to the
    /// coordinator. The reconciler derives it, but the coordinator remains the owner of storage.
    case valid(
        session: ActiveSuggestionSession,
        advancement: SuggestionSessionAdvancement?,
        nextPendingInsertionConsumedCount: Int?
    )
    case invalid(String)
}

/// Pure interaction policy for partial acceptance and live editor reconciliation.
enum SuggestionSessionReconciler {
    /// Advances the buffered session only when the user's direct typed characters exactly match
    /// the next expected suggestion tail.
    static func advanceIfTypedCharactersMatch(
        _ typedCharacters: String,
        session: ActiveSuggestionSession
    ) -> ActiveSuggestionSession? {
        guard typedCharacters.isDirectTextMutation else {
            return nil
        }

        guard session.remainingText.hasPrefix(typedCharacters) else {
            return nil
        }

        return session.advancing(by: typedCharacters.count)
    }

    /// Reconciles the active suggestion session with live AX editor state while preserving the
    /// current lag-tolerance sentinel for recently injected text.
    static func reconcile(
        session: ActiveSuggestionSession,
        with liveContext: FocusedInputContext,
        pendingInsertionConsumedCount: Int?
    ) -> SuggestionSessionReconciliation {
        let isAwaitingInsertedTextSync = pendingInsertionConsumedCount == session.consumedCharacterCount

        // Process-level identity check instead of AX element identity. Chrome recycles AX
        // node tokens between polls, making CFHash-based elementIdentifier unstable. The text
        // guards below catch intra-process field switches via content divergence.
        guard liveContext.processIdentifier == session.baseContext.processIdentifier else {
            return .invalid("Overlay hidden because the focused field changed.")
        }

        guard liveContext.selection.length == 0 else {
            return .invalid("Overlay hidden because text is selected.")
        }

        if let trailingTextReconciliation = reconcileTrailingText(
            session: session,
            liveContext: liveContext,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount,
            isAwaitingInsertedTextSync: isAwaitingInsertedTextSync
        ) {
            return trailingTextReconciliation
        }

        if let prefixReconciliation = reconcilePrefixAnchor(
            session: session,
            liveContext: liveContext,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount,
            isAwaitingInsertedTextSync: isAwaitingInsertedTextSync
        ) {
            return prefixReconciliation
        }

        var nextPendingInsertionConsumedCount = pendingInsertionConsumedCount
        let consumedSuffix = String(liveContext.precedingText.dropFirst(session.baseContext.precedingText.count))
        if let consumedTextReconciliation = reconcileConsumedSuggestionText(
            session: session,
            consumedSuffix: consumedSuffix,
            pendingInsertionConsumedCount: pendingInsertionConsumedCount,
            isAwaitingInsertedTextSync: isAwaitingInsertedTextSync
        ) {
            return consumedTextReconciliation
        }

        // AX caught up (or never lagged) — clear the sentinel.
        if nextPendingInsertionConsumedCount != nil,
           consumedSuffix.count >= session.consumedCharacterCount {
            nextPendingInsertionConsumedCount = nil
        }

        guard consumedSuffix.count >= session.consumedCharacterCount else {
            // Same AX lag protection: if we just Tab-inserted, the preceding text hasn't updated yet.
            if isAwaitingInsertedTextSync {
                return tolerateTransientPostInsertionLag(
                    session: session,
                    pendingInsertionConsumedCount: pendingInsertionConsumedCount
                )
            }

            return .invalid("Overlay hidden because the active suggestion was partially undone.")
        }

        let reconciledSession = session.withConsumedCharacters(consumedSuffix.count)
        guard consumedSuffix.count != session.consumedCharacterCount else {
            return .valid(
                session: reconciledSession,
                advancement: nil,
                nextPendingInsertionConsumedCount: nextPendingInsertionConsumedCount
            )
        }

        let advancedBy = consumedSuffix.count - session.consumedCharacterCount
        let advancement = SuggestionSessionAdvancement(
            stage: reconciledSession.isExhausted ? "session-exhausted" : "session-reconciled",
            message: reconciledSession.isExhausted
                ? "The live field state caught up with the fully consumed suggestion."
                : "The live field state consumed \(advancedBy) additional suggestion characters.",
            actionSummary: "Suggestion tail advanced from live editor state.",
            exhaustionStage: "session-exhausted",
            exhaustionMessage: "The live field state fully consumed the active suggestion."
        )

        return .valid(
            session: reconciledSession,
            advancement: advancement,
            nextPendingInsertionConsumedCount: nextPendingInsertionConsumedCount
        )
    }

    private static func tolerateTransientPostInsertionLag(
        session: ActiveSuggestionSession,
        pendingInsertionConsumedCount: Int?
    ) -> SuggestionSessionReconciliation {
        .valid(
            session: session,
            advancement: nil,
            nextPendingInsertionConsumedCount: pendingInsertionConsumedCount
        )
    }

    private static func reconcileTrailingText(
        session: ActiveSuggestionSession,
        liveContext: FocusedInputContext,
        pendingInsertionConsumedCount: Int?,
        isAwaitingInsertedTextSync: Bool
    ) -> SuggestionSessionReconciliation? {
        guard liveContext.trailingText != session.baseContext.trailingText else {
            return nil
        }

        // Chromium editors can briefly publish a selection/caret update before their surrounding
        // text snapshot catches up. Right after Tab insertion that makes the trailing-text slice
        // look changed even though the active suggestion tail is still valid.
        if isAwaitingInsertedTextSync,
           liveContext.precedingText.hasPrefix(session.baseContext.precedingText) {
            return tolerateTransientPostInsertionLag(
                session: session,
                pendingInsertionConsumedCount: pendingInsertionConsumedCount
            )
        }

        return .invalid("Overlay hidden because text after the caret changed.")
    }

    private static func reconcilePrefixAnchor(
        session: ActiveSuggestionSession,
        liveContext: FocusedInputContext,
        pendingInsertionConsumedCount: Int?,
        isAwaitingInsertedTextSync: Bool
    ) -> SuggestionSessionReconciliation? {
        guard !liveContext.precedingText.hasPrefix(session.baseContext.precedingText) else {
            return nil
        }

        // The inverse Chromium race can also happen: the trailing text is already stable, but the
        // prefix before the caret still reflects the pre-insertion snapshot. In that case we wait
        // for AX to settle instead of eagerly killing the session.
        if isAwaitingInsertedTextSync {
            return tolerateTransientPostInsertionLag(
                session: session,
                pendingInsertionConsumedCount: pendingInsertionConsumedCount
            )
        }

        return .invalid("Overlay hidden because text before the caret no longer matches the suggestion anchor.")
    }

    private static func reconcileConsumedSuggestionText(
        session: ActiveSuggestionSession,
        consumedSuffix: String,
        pendingInsertionConsumedCount: Int?,
        isAwaitingInsertedTextSync: Bool
    ) -> SuggestionSessionReconciliation? {
        guard !session.fullText.hasPrefix(consumedSuffix) else {
            return nil
        }

        // If we just inserted via Tab, AX may still show stale text. Trust the sentinel for one
        // reconciliation cycle instead of invalidating the whole session.
        if isAwaitingInsertedTextSync {
            return tolerateTransientPostInsertionLag(
                session: session,
                pendingInsertionConsumedCount: pendingInsertionConsumedCount
            )
        }

        return .invalid("Overlay hidden because typed text diverged from the active suggestion.")
    }

    /// Accepts optional leading whitespace plus the next visible token.
    /// This is intentionally a user-facing chunking rule rather than a model-token rule.
    static func nextAcceptanceChunk(from remainingText: String) -> String {
        guard !remainingText.isEmpty else {
            return ""
        }

        var index = remainingText.startIndex
        while index < remainingText.endIndex, remainingText[index].isWhitespace {
            index = remainingText.index(after: index)
        }

        while index < remainingText.endIndex, !remainingText[index].isWhitespace {
            index = remainingText.index(after: index)
        }

        return String(remainingText[..<index])
    }

    /// Counts word-like tokens so punctuation-only accepts do not inflate productivity metrics.
    static func acceptedWordCount(in text: String) -> Int {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .filter { token in
                token.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) })
            }
            .count
    }

    static func overlayHideReason(for event: CapturedInputEvent) -> String {
        switch event.kind {
        case .textMutation, .shortcutMutation:
            return "Overlay hidden because typing invalidated the current suggestion."
        case .navigation:
            return "Overlay hidden because caret navigation invalidated the current suggestion."
        case .dismissal:
            return "Overlay hidden because a dismissal key was pressed."
        case .tab, .other:
            return "Overlay hidden."
        }
    }

    /// The overlay may be hidden briefly while waiting for the host app to publish an updated
    /// caret position, so hidden does not automatically mean "reject Tab."
    static func overlayAllowsAcceptance(of text: String, overlayState: OverlayState) -> Bool {
        guard case let .visible(visibleText, _) = overlayState else {
            return true
        }

        return visibleText == text
    }
}

private extension String {
    /// Direct text input is the only mutation we can safely reconcile optimistically from the
    /// key event alone. Control characters such as backspace or return require regeneration.
    var isDirectTextMutation: Bool {
        guard !isEmpty else {
            return false
        }

        return unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
