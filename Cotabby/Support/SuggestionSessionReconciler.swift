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
    ///
    /// When `autoAcceptTrailingPunctuation` is false, punctuation that trails a word is treated as
    /// its own acceptance part: the chunk stops after the word's last alphanumeric character so a
    /// user can accept "you" without being forced to also take the "?" in "you?". The leftover
    /// punctuation is returned whole on the next call. Punctuation that sits inside a word
    /// (the apostrophe in "don't", the interior dots in "U.S.A") is preserved because it is not
    /// trailing.
    ///
    /// This is intentionally a user-facing chunking rule rather than a model-token rule.
    static func nextAcceptanceChunk(
        from remainingText: String,
        autoAcceptTrailingPunctuation: Bool = true
    ) -> String {
        guard !remainingText.isEmpty else {
            return ""
        }

        var index = remainingText.startIndex
        while index < remainingText.endIndex, remainingText[index].isWhitespace {
            index = remainingText.index(after: index)
        }

        let tokenStart = index
        while index < remainingText.endIndex, !remainingText[index].isWhitespace {
            index = remainingText.index(after: index)
        }

        if !autoAcceptTrailingPunctuation,
           let wordEnd = wordEndTrimmingTrailingPunctuation(in: remainingText, from: tokenStart, to: index) {
            index = wordEnd
        }

        return String(remainingText[..<index])
    }

    /// Returns the index just past a word token's final alphanumeric character when that token has
    /// trailing punctuation worth splitting off. Returns `nil` — meaning "accept the whole token" —
    /// for punctuation-only tokens and for words that already end in an alphanumeric character.
    private static func wordEndTrimmingTrailingPunctuation(
        in text: String,
        from tokenStart: String.Index,
        to tokenEnd: String.Index
    ) -> String.Index? {
        var lastWordCharacterEnd: String.Index?
        var cursor = tokenStart
        while cursor < tokenEnd {
            if text[cursor].isAcceptanceWordCharacter {
                lastWordCharacterEnd = text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }

        guard let wordEnd = lastWordCharacterEnd, wordEnd < tokenEnd else {
            return nil
        }

        return wordEnd
    }

    /// Returns the text to actually type for an acceptance chunk, dropping its leading whitespace run
    /// when the live text before the caret already ends in whitespace — so accepting never stacks a
    /// second space onto a boundary the field already provides.
    ///
    /// This is the authoritative, accept-time counterpart to the generation-time space handling in
    /// `SuggestionTextNormalizer`. That normalizer decides whether to keep the model's leading space
    /// against a prefix *snapshot* taken when the request was built, which can be stale by the time
    /// the user accepts — most often because they typed the separating space themselves after the
    /// ghost appeared, or because AX reported the prefix before that space landed. Reconciling here
    /// against the live preceding text makes the boundary deterministic instead of relying on the
    /// timing-sensitive session reconciler to consume the typed space first.
    ///
    /// The session still advances by the full (untrimmed) chunk: the whitespace we skip typing is
    /// exactly the whitespace already present in the field, so the consumed-suffix accounting the
    /// reconciler does after insertion still lines up.
    static func insertionChunk(forAcceptedChunk chunk: String, precedingText: String) -> String {
        guard let lastScalar = precedingText.unicodeScalars.last,
              CharacterSet.whitespaces.contains(lastScalar) else {
            return chunk
        }

        return String(chunk.drop(while: { $0.isWhitespace }))
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
        case .acceptance, .fullAcceptance, .other:
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

private extension Character {
    /// Alphanumerics form the core of a "word"; everything else trailing a word is punctuation that
    /// can be peeled into its own acceptance part when auto-accept is disabled.
    var isAcceptanceWordCharacter: Bool {
        isLetter || isNumber
    }
}
