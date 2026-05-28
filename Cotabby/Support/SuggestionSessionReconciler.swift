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

    /// Accepts a full phrase up to the next sentence terminator (`.`, `!`, `?`, `\n`) or the end
    /// of the buffered suggestion tail. Composes over `nextAcceptanceChunk` so word-boundary,
    /// internal-punctuation, and leading-whitespace policy stay identical across the seams of a
    /// multi-word accept.
    ///
    /// Newlines need an extra rule: `nextAcceptanceChunk` returns leading whitespace as part of
    /// the next chunk, so a tail like `Hello\nworld` would surface `\n` as the leading character
    /// of the second chunk rather than the trailing character of the first. The in-chunk newline
    /// scan below catches that — without it, phrase mode would silently cross paragraph breaks.
    ///
    /// Sentence-terminating `.!?` are detected via the accumulated tail's tail-end after walking
    /// past any closing-punctuation run. This catches both the plain case (`done.`) and the
    /// quoted-prose case (`"done." Next` → stop after the closing quote). Without the walk-back,
    /// the chunk's last character would be `"` rather than `.` and phrase mode would over-accept
    /// the next sentence. Token-interior punctuation like the dots in `U.S.A` does NOT trigger
    /// an early break because the chunk's tail (after walking) is `A`, not `.`. The known
    /// false-positive is when the tail itself ends with `U.S.A.` — the trailing period reads as
    /// a sentence terminator and the user has to press once more for the next phrase. Rule-based
    /// scanners can't disambiguate that without NLP; Cursor and Copilot behave the same way.
    ///
    /// The `autoAcceptTrailingPunctuation` flag is passed through to each underlying chunk call
    /// but does not change the final phrase output: a tail like `you?` with the flag off yields
    /// chunks `"you"` then `"?"`, accumulated to `"you?"`, terminator-suffixed → stop. Net match
    /// to the flag-on case where the first chunk is already `"you?"`.
    static func nextAcceptancePhrase(
        from remainingText: String,
        autoAcceptTrailingPunctuation: Bool = true
    ) -> String {
        guard !remainingText.isEmpty else {
            return ""
        }

        var accumulated = ""
        var working = remainingText

        while !working.isEmpty {
            let chunk = nextAcceptanceChunk(
                from: working,
                autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation
            )
            guard !chunk.isEmpty else {
                break
            }

            if let newlineIndex = chunk.firstIndex(of: "\n") {
                accumulated += chunk[...newlineIndex]
                return accumulated
            }

            accumulated += chunk
            working = String(working.dropFirst(chunk.count))

            if endsInSentenceTerminator(accumulated) {
                return accumulated
            }
        }

        return accumulated
    }

    /// Tail-end check for sentence terminators that survives closing quotes and brackets, so
    /// `"done."` and `(yes!)` are recognized as phrase ends even though their final character is
    /// a closer rather than `.!?`. Walks back past any run of closing punctuation, then checks
    /// whether the character immediately before that run is a sentence terminator.
    private static func endsInSentenceTerminator(_ text: String) -> Bool {
        var index = text.endIndex
        while index > text.startIndex {
            let prev = text.index(before: index)
            if text[prev].isPhraseClosingPunctuation {
                index = prev
            } else {
                break
            }
        }
        guard index > text.startIndex else {
            return false
        }
        let prev = text.index(before: index)
        return text[prev].isPhraseSentenceTerminator
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

    /// Returns the text to actually type for an acceptance chunk, reconciling the word boundary
    /// against the live text before the caret. Two complementary rules run here:
    ///
    /// 1. If the live preceding text already ends in horizontal whitespace, drop the chunk's leading
    ///    whitespace run so we never stack a second space onto a boundary the field already provides.
    /// 2. If the live preceding text ends in a word character and the chunk starts in a word
    ///    character, insert a single space between them so the suggestion doesn't glue onto the
    ///    user's last word.
    ///
    /// Rule 1 is the accept-time counterpart to the generation-time space handling in
    /// `SuggestionTextNormalizer`. That normalizer decides whether to keep the model's leading space
    /// against a prefix *snapshot* taken when the request was built, which can be stale by the time
    /// the user accepts — most often because they typed the separating space themselves after the
    /// ghost appeared, or because AX reported the prefix before that space landed.
    ///
    /// Rule 2 is the inverse: when the model emits a fresh word without its own leading space
    /// (either because the small local model just omitted one, or because the normalizer stripped it
    /// against a stale snapshot that thought the field ended in whitespace), there is no boundary in
    /// the chunk and none in the field. We add the boundary explicitly here so accept never glues
    /// "Hello"+"World" into "HelloWorld". The tradeoff is that we don't try to distinguish a fresh
    /// new word from a partial-word completion — Cotabby's prompt is biased toward continuing at the
    /// caret with multi-word output, so the "new word" interpretation matches what users see.
    ///
    /// Session accounting: rule 1 advances the session by the full (untrimmed) acceptedChunk; the
    /// whitespace we skip typing is the field's own, so the consumed-suffix reconciliation lines up.
    /// Rule 2 types one character the session does NOT account for — fullText has no leading space
    /// to consume, so the post-insertion reconciler enters its tolerate path and the session stays
    /// alive for follow-up word-by-word accepts. A user who then types a character that would have
    /// typed-matched the next suggestion char will fall out of the tolerate window and the session
    /// will be invalidated, which is acceptable: the next prediction picks up from the corrected
    /// field state without any visible glue.
    static func insertionChunk(forAcceptedChunk chunk: String, precedingText: String) -> String {
        if let lastScalar = precedingText.unicodeScalars.last,
           CharacterSet.whitespaces.contains(lastScalar) {
            // The drop predicate mirrors the guard's horizontal-whitespace definition so a chunk
            // that legitimately starts with a newline (e.g. a full-accept spanning a line break) is
            // not silently dropped when the field happens to end in a space or tab.
            return String(chunk.drop(while: { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) }))
        }

        guard let firstChunkChar = chunk.first,
              firstChunkChar.isAcceptanceWordCharacter,
              let lastPrecedingChar = precedingText.last,
              lastPrecedingChar.isAcceptanceWordCharacter else {
            return chunk
        }

        return " " + chunk
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
        guard case let .visible(visibleText, _, _) = overlayState else {
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

    /// Sentence-ending punctuation for phrase mode. `\n` is handled separately because it can
    /// appear inside a leading-whitespace prefix of a composed chunk rather than at the chunk's
    /// tail end.
    var isPhraseSentenceTerminator: Bool {
        self == "." || self == "!" || self == "?"
    }

    /// Closing punctuation that may follow a sentence terminator in prose: straight + curly
    /// quotes, parentheses, square brackets, and braces. The phrase scanner walks back past a
    /// run of these to find the real sentence terminator underneath, so `"done."` stops as a
    /// complete sentence even though its final character is the closing quote.
    var isPhraseClosingPunctuation: Bool {
        self == "\"" || self == "'" || self == ")" || self == "]" || self == "}"
            || self == "\u{201D}" || self == "\u{2019}"
    }
}
