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

        // Space-less scripts (CJK, Japanese, Korean, Thai, ...) put no whitespace between words, so the
        // whitespace scan above swallows an entire run as a single "word". When the token begins with
        // such a script, segment it with ICU word breaking and accept only the first word, so one Tab
        // advances by a single word the way it does in space-delimited text. Space-delimited scripts
        // never enter this branch, so Latin / Cyrillic / Arabic acceptance stays byte-for-byte unchanged.
        if tokenStart < index,
           remainingText[tokenStart].beginsSpacelessScriptWord,
           let wordEnd = firstSegmentedWordEnd(in: remainingText, from: tokenStart, notPast: index) {
            index = wordEnd
        }

        if !autoAcceptTrailingPunctuation,
           let wordEnd = wordEndTrimmingTrailingPunctuation(in: remainingText, from: tokenStart, to: index) {
            index = wordEnd
        }

        return String(remainingText[..<index])
    }

    /// The index just past the first ICU word in `text[from..<limit]`, or nil when segmentation finds
    /// no word there. Only the space-less-script branch of `nextAcceptanceChunk` calls this; the result
    /// is clamped to `limit` so it can never extend past the non-whitespace token the caller already
    /// bounded. `.substringNotRequired` skips materializing the word string we don't need.
    private static func firstSegmentedWordEnd(
        in text: String,
        from start: String.Index,
        notPast limit: String.Index
    ) -> String.Index? {
        var wordEnd: String.Index?
        text.enumerateSubstrings(in: start..<limit, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            wordEnd = range.upperBound
            stop = true
        }
        guard let wordEnd, wordEnd > start else {
            return nil
        }
        return min(wordEnd, limit)
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
    /// an early break because the chunk's tail (after walking) is `A`, not `.`. Periods are further
    /// disambiguated by `SentenceBoundaryClassifier`, so decimals ("1.2"), list numbers ("1."),
    /// single-letter initials, and common abbreviations ("e.g.", "U.S.") do not end a phrase. Truly
    /// ambiguous cases (a real sentence ending in an abbreviation) lean toward continuing, which is
    /// the safe default for phrase acceptance.
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
        guard text[prev].isPhraseSentenceTerminator else {
            return false
        }
        // `!` and `?` always end a sentence. A period is ambiguous: decimals, list/ordinal numbers,
        // single-letter initials, and common abbreviations are not sentence ends, so consult the
        // classifier rather than treating every "." as terminal.
        if text[prev] == "." {
            return SentenceBoundaryClassifier.isTerminalPeriod(in: text, at: prev)
        }
        return true
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

    /// Returns the text to actually type for an acceptance chunk, reconciling the chunk's leading
    /// whitespace against the live text before the caret.
    ///
    /// One rule runs here: if the live preceding text already ends in horizontal whitespace, drop the
    /// chunk's leading whitespace run so we never stack a second space onto a boundary the field
    /// already provides. This is the accept-time counterpart to the generation-time space handling in
    /// `SuggestionTextNormalizer`, re-checked against live text because the request-time prefix
    /// snapshot can be stale by the time the user accepts — most often because they typed the
    /// separating space themselves after the ghost appeared, or because AX reported the prefix before
    /// that space landed.
    ///
    /// We deliberately do NOT synthesize a word boundary. The base-model prompt ends at a clean
    /// boundary (`BaseCompletionPromptRenderer` trims trailing whitespace), so the model's first token
    /// already encodes intent: a leading space means "new word", none means "continue the current
    /// word". Honoring that is what makes a mid-word completion like "after" + "noon" land as
    /// "afternoon" instead of "after noon", while a genuine new word arrives with the model's own
    /// leading space already attached to the first acceptance chunk (`nextAcceptanceChunk` keeps it).
    /// The cost of trusting the model is that when it omits a space it should have emitted, the words
    /// glue ("Hello" + "World" -> "HelloWorld") — but that glue is exactly what the ghost text showed,
    /// so accept stays WYSIWYG rather than inserting a separator the user never saw. A previous
    /// version synthesized that separator here and produced the inverse, more confusing bug: ghost
    /// text "afternoon" that committed as "after noon".
    ///
    /// Session accounting: the session advances by the full (untrimmed) acceptedChunk; the only
    /// whitespace we skip typing is the field's own, so the consumed-suffix reconciliation lines up.
    static func insertionChunk(forAcceptedChunk chunk: String, precedingText: String) -> String {
        guard let lastScalar = precedingText.unicodeScalars.last,
              CharacterSet.whitespaces.contains(lastScalar) else {
            // Field does not end in whitespace: type the chunk verbatim and let the model's own
            // leading space (or its absence) decide the boundary.
            return chunk
        }

        // The drop predicate mirrors the guard's horizontal-whitespace definition so a chunk that
        // legitimately starts with a newline (e.g. a full-accept spanning a line break) is not
        // silently dropped when the field happens to end in a space or tab.
        return String(chunk.drop(while: { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) }))
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

    /// True when a freshly generated suggestion only reproduces the chunk the user just fully
    /// accepted while the live field still shows the exact pre-acceptance text. That pairing is the
    /// signature of the Chromium AX-publish race: the synthetic insert has not surfaced in AX yet, so
    /// the model regenerated against stale text and proposed the same tail again. Dropping it breaks
    /// the final-word accept/regenerate/accept loop. Any change to the preceding text (the insert
    /// landed, or the user typed) flips this to false so a legitimately repeated continuation still
    /// shows.
    static func isStaleAcceptanceEcho(
        resultText: String,
        acceptedChunk: String,
        currentPrecedingText: String,
        acceptedPrecedingText: String
    ) -> Bool {
        let trimmedChunk = acceptedChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else {
            return false
        }
        guard resultText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedChunk else {
            return false
        }
        return currentPrecedingText == acceptedPrecedingText
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
    /// True when the character begins a word of a space-less script (Han, Hiragana, Katakana, Hangul,
    /// Thai, Lao, Khmer, Myanmar, ...). These scripts write words without separating spaces, so the
    /// whitespace-run acceptance rule would over-accept a whole run; `nextAcceptanceChunk` switches to
    /// ICU word segmentation when a token begins with one of them. Detection is by leading scalar so it
    /// stays a cheap, allocation-free check on the common (space-delimited) path.
    var beginsSpacelessScriptWord: Bool {
        guard let scalar = unicodeScalars.first else {
            return false
        }
        switch scalar.value {
        case 0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xAC00...0xD7A3,   // Hangul syllables
             0x1100...0x11FF,   // Hangul Jamo
             0x0E00...0x0E7F,   // Thai
             0x0E80...0x0EFF,   // Lao
             0x1780...0x17FF,   // Khmer
             0x1000...0x109F,   // Myanmar
             0x20000...0x2A6DF, // CJK Unified Ideographs Extension B
             0x30000...0x3134F: // CJK Unified Ideographs Extension G
            return true
        default:
            return false
        }
    }

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
