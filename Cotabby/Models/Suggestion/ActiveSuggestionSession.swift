import Foundation

/// Durable interaction state for type-through and partial acceptance after generation completes.

/// Represents one active inline-completion session after the model has produced a suggestion.
/// The key architectural shift is that a suggestion is no longer "fire once and forget."
/// Instead, it becomes durable interaction state that can be partially consumed over time.
struct ActiveSuggestionSession: Equatable, Sendable {
    /// The focused field state that produced the original suggestion.
    /// We keep this as the anchor so later text changes can be interpreted as:
    /// "user consumed part of the suggestion" vs "user diverged from it."
    let baseContext: FocusedInputContext
    let fullText: String
    let consumedCharacterCount: Int
    let latency: TimeInterval
    /// `.continuation` for normal forward suggestions; `.correction(typoWord:)` when the session
    /// represents a typo fix. The acceptance path branches on this so corrections always commit the
    /// whole word and replace the typo rather than appending forward text.
    let kind: SuggestionKind

    init(
        baseContext: FocusedInputContext,
        fullText: String,
        consumedCharacterCount: Int = 0,
        latency: TimeInterval,
        kind: SuggestionKind = .continuation
    ) {
        self.baseContext = baseContext
        self.fullText = fullText
        self.consumedCharacterCount = min(max(consumedCharacterCount, 0), fullText.count)
        self.latency = latency
        self.kind = kind
    }

    var remainingText: String {
        fullText.droppingLeadingCharacters(consumedCharacterCount)
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
        remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns a new session advanced by the accepted or typed character count.
    /// The original value stays unchanged because this type models immutable interaction state.
    func advancing(by consumedCharacters: Int) -> ActiveSuggestionSession {
        ActiveSuggestionSession(
            baseContext: baseContext,
            fullText: fullText,
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
            consumedCharacterCount: consumedCharacters,
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
