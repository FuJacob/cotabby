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
    /// suggestion. `replacingLength` is the grapheme count to delete from the live field on accept.
    case correct(word: String, correctedWord: String, replacingLength: Int)
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
        guard let current = CurrentWordExtractor.extract(from: precedingText) else {
            return .proceed
        }
        guard isTypo(current.word) else {
            return .proceed
        }
        if offerTypoCorrections, let corrected = bestCorrection(current.word) {
            return .correct(
                word: current.word,
                correctedWord: corrected,
                replacingLength: current.characterCount
            )
        }
        return .suppress
    }
}
