import Foundation

/// Represents one active inline-completion session after the model has produced a suggestion.
/// `SuggestionInteractionState` owns this immutable value while the user accepts or types through
/// it. Prediction and presentation have separate boundaries: the model may know the next phrase
/// while the ghost offers only a word ending or one word. Consuming that visible portion reveals
/// the already predicted continuation without rebuilding the request or resetting its AX anchor.
struct ActiveSuggestionSession: Equatable, Sendable {
    /// The focused field state that produced the original suggestion.
    /// We keep this as the anchor so later text changes can be interpreted as:
    /// "user consumed part of the suggestion" vs "user diverged from it."
    let baseContext: FocusedInputContext
    /// All predicted text, including following words that have not been offered for acceptance yet.
    let fullText: String
    /// Absolute character boundary for the first offer, usually an uncertain word ending. Once
    /// consumption reaches this boundary, the following text can be offered. Nil has no first-step
    /// restriction; retaining nil matters when streaming later extends an unrestricted prediction.
    let initialVisibleCharacterCount: Int?
    /// False presents one acceptance word at a time, while retaining the complete predicted tail.
    let showFollowingWords: Bool
    let consumedCharacterCount: Int
    let latency: TimeInterval
    /// `.continuation` for normal forward suggestions; `.correction(typoWord:)` when the session
    /// represents a typo fix. The acceptance path branches on this so corrections always commit the
    /// whole word and replace the typo rather than appending forward text.
    let kind: SuggestionKind

    init(
        baseContext: FocusedInputContext,
        fullText: String,
        initialVisibleCharacterCount: Int? = nil,
        showFollowingWords: Bool = true,
        consumedCharacterCount: Int = 0,
        latency: TimeInterval,
        kind: SuggestionKind = .continuation
    ) {
        self.baseContext = baseContext
        self.fullText = fullText
        self.initialVisibleCharacterCount = initialVisibleCharacterCount.map { min(max($0, 0), fullText.count) }
        self.showFollowingWords = showFollowingWords
        self.consumedCharacterCount = min(max(consumedCharacterCount, 0), fullText.count)
        self.latency = latency
        self.kind = kind
    }

    /// The full buffered tail is used to reconcile user-authored text and decide exhaustion. It
    /// must not be used for acceptance: accepting an unseen following word would break the promise
    /// that Tab inserts only the ghost currently offered to the user.
    var predictedRemainingText: String {
        fullText.droppingLeadingCharacters(consumedCharacterCount)
    }

    /// The next visible and acceptable offer. This advances through the buffered prediction even
    /// in one-word mode, so a smaller ghost does not require a fresh model call after every word.
    var remainingText: String {
        let availableText: String
        if let initialVisibleCharacterCount, consumedCharacterCount < initialVisibleCharacterCount {
            availableText = fullText.leadingCharacters(initialVisibleCharacterCount)
                .droppingLeadingCharacters(consumedCharacterCount)
        } else {
            availableText = predictedRemainingText
        }
        return showFollowingWords
            ? availableText
            : SuggestionSessionReconciler.nextAcceptanceChunk(from: availableText)
    }

    var hasBufferedContinuation: Bool {
        predictedRemainingText.count > remainingText.count
    }

    var acceptedCount: Int {
        consumedCharacterCount
    }

    var remainingCount: Int {
        remainingText.count
    }

    /// A whitespace-only tail is effectively exhausted for inline UX.
    /// Showing "ghost spaces" is visually confusing and not worth preserving.
    var isExhausted: Bool {
        predictedRemainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns a new session advanced by the accepted or typed character count.
    /// The original value stays unchanged because this type models immutable interaction state.
    func advancing(by consumedCharacters: Int) -> ActiveSuggestionSession {
        ActiveSuggestionSession(
            baseContext: baseContext,
            fullText: fullText,
            initialVisibleCharacterCount: initialVisibleCharacterCount,
            showFollowingWords: showFollowingWords,
            consumedCharacterCount: self.consumedCharacterCount + max(consumedCharacters, 0),
            latency: latency,
            kind: kind
        )
    }

    /// Rebuilds the session from a fully observed live editor state during reconciliation.
    /// This is useful when AX catches up after optimistic UI updates such as partial Tab accepts.
    func withConsumedCharacters(_ consumedCharacters: Int) -> ActiveSuggestionSession {
        ActiveSuggestionSession(
            baseContext: baseContext,
            fullText: fullText,
            initialVisibleCharacterCount: initialVisibleCharacterCount,
            showFollowingWords: showFollowingWords,
            consumedCharacterCount: consumedCharacters,
            latency: latency,
            kind: kind
        )
    }

    /// Streaming and lookahead may append prediction text, but cannot revise characters the user
    /// has already seen or consumed. The unchanged anchor and consumed position let the interaction
    /// owner preserve any outstanding AX-publication sentinel while adding useful following words.
    func extendingPrediction(to extendedText: String) -> ActiveSuggestionSession? {
        guard !kind.isCorrection, extendedText.hasPrefix(fullText) else { return nil }
        return ActiveSuggestionSession(
            baseContext: baseContext,
            fullText: extendedText,
            initialVisibleCharacterCount: initialVisibleCharacterCount,
            showFollowingWords: showFollowingWords,
            consumedCharacterCount: consumedCharacterCount,
            latency: latency,
            kind: kind
        )
    }
}

/// Records the chunk committed by the most recent full acceptance and the field text it was
/// appended after. The coordinator stamps this on a final-chunk accept and consumes it on the next
/// generation. If the model only re-proposes `text` while the live preceding text still equals
/// `precedingText`, the host has not published our insert yet (the Chromium AX-publish race), so the
/// suggestion is dropped instead of looping accept/regenerate/accept on the last word.
struct AcceptedSuggestionTail: Equatable, Sendable {
    let text: String
    let precedingText: String
}

private extension String {
    /// Swift `String` is a collection of extended grapheme clusters, not bytes.
    /// These helpers slice by user-visible characters so emoji and composed characters stay intact.
    /// That matters because autocomplete acceptance is a user-facing action, not a byte-level one.
    func leadingCharacters(_ count: Int) -> String {
        String(prefix(max(count, 0)))
    }

    func droppingLeadingCharacters(_ count: Int) -> String {
        String(dropFirst(max(count, 0)))
    }
}
