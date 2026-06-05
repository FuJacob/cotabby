import Foundation

/// File overview:
/// Pure decision rule for the typo gate that runs before each prediction. Extracted from
/// `SuggestionCoordinator` so the "suppress vs correct vs proceed" logic is unit-testable without
/// `NSSpellChecker` or a live AX snapshot: the coordinator passes the spell-check behaviors in as
/// closures, and tests pass deterministic stubs.
enum TypoGateDecision: Equatable {
    /// No actionable typo on the current word. Proceed with a normal continuation.
    case proceed
    /// The current word looks misspelled and corrections are off (or none was available). Hide the
    /// continuation so completions never pile on top of a broken word, but show nothing.
    case suppress
    /// The current word looks misspelled and a correction is available. Offer it as a replace-the-word
    /// suggestion. `word` is the typo to replace; the accept path recomputes the delete length from
    /// the live field rather than trusting a value captured here.
    case correct(word: String, correctedWord: String)
}

enum TypoGate {
    /// Resolves the gate decision for the trailing word of `precedingText`.
    ///
    /// `isTypo` and `bestCorrection` are injected so this stays pure: in production they wrap
    /// `CurrentWordSpellChecker`; in tests they are stubs. Correction requires both toggles on AND a
    /// non-nil correction; otherwise a detected typo falls back to suppression.
    static func resolve(
        precedingText: String,
        suppressCompletionsOnTypo: Bool,
        offerTypoCorrections: Bool,
        isTypo: (String) -> Bool,
        bestCorrection: (String) -> String?
    ) -> TypoGateDecision {
        guard suppressCompletionsOnTypo else {
            return .proceed
        }
        // Tolerate one trailing space so a just-finished word (the user typed it and pressed space)
        // is still offered a correction instead of the offer vanishing the moment space is pressed.
        guard let current = CurrentWordExtractor.extractTrailingWord(from: precedingText)?.result else {
            return .proceed
        }
        guard isTypo(current.word) else {
            return .proceed
        }
        if offerTypoCorrections, let corrected = bestCorrection(current.word) {
            return .correct(word: current.word, correctedWord: corrected)
        }
        return .suppress
    }
}
