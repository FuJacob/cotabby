import Foundation

/// Pure state machine that recognizes a double press of the Accept Word key.
///
/// When the user enables "double-tap to accept the entire suggestion", the first press still accepts
/// one word immediately (no added latency on the common single-press path), and a second press of the
/// same key inside `window` accepts everything that remains. The net effect of the pair is that the
/// whole suggestion lands in the field.
///
/// The coordinator owns one instance for its lifetime and supplies the clock and the session token.
/// Keeping the timing rule here, instead of inline in the coordinator, makes the invariants testable:
/// a pair only counts on the *same* suggestion, inside the window, and each pair is consumed once so a
/// triple press cannot promote twice.
struct DoubleTapAcceptanceState: Equatable {
    /// Identifies one suggestion across its word-by-word advancement. Accepting a word keeps the
    /// session's generation and full text and only moves its consumed count, so these two values
    /// stay stable between the two presses, while a regenerated suggestion changes the generation.
    struct SessionToken: Equatable {
        let generation: UInt64
        let fullText: String
    }

    /// Longest gap between the two presses that still counts as a double tap. Shorter than the
    /// system double-click interval (0.5 s by default) so deliberate one-word-at-a-time Tabbing at a
    /// normal pace keeps accepting single words.
    static let window: TimeInterval = 0.3

    private struct PendingPress: Equatable {
        let session: SessionToken
        let uptime: TimeInterval
    }

    private var pendingPress: PendingPress?

    var hasPendingPress: Bool {
        pendingPress != nil
    }

    /// Remembers a first press that accepted a word and left the suggestion with text remaining.
    mutating func recordWordAccept(of session: SessionToken, at uptime: TimeInterval) {
        pendingPress = PendingPress(session: session, uptime: uptime)
    }

    /// Returns true when this press completes a double tap. Always clears the pending press, so a
    /// missed pair does not linger and a completed pair cannot be reused by a third press.
    mutating func consumeDoubleTap(of session: SessionToken, at uptime: TimeInterval) -> Bool {
        defer { pendingPress = nil }
        guard let pendingPress, pendingPress.session == session else {
            return false
        }
        let elapsed = uptime - pendingPress.uptime
        return elapsed >= 0 && elapsed <= Self.window
    }

    /// Cancels a pending first press, e.g. when the user types or moves the caret between presses.
    mutating func reset() {
        pendingPress = nil
    }
}

extension DoubleTapAcceptanceState.SessionToken {
    init(session: ActiveSuggestionSession) {
        self.init(generation: session.baseContext.generation, fullText: session.fullText)
    }
}
