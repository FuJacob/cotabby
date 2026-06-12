import Foundation

/// File overview:
/// Pure decision rule for the typo gate that runs before each prediction. Extracted from
/// `SuggestionCoordinator` so the "suppress vs correct vs proceed" logic is unit-testable without
/// `NSSpellChecker` or a live AX snapshot: the coordinator passes the spell-check behaviors in as
/// closures, and tests pass deterministic stubs.
nonisolated enum TypoGateDecision: Equatable {
    /// No actionable typo on the current word. Proceed with a normal continuation.
    case proceed
    /// The current word looks misspelled and corrections are off (or none was available). Hide the
    /// continuation so completions never pile on top of a broken word, but show nothing.
    case suppress
    /// The current word looks misspelled and a correction is available. Offer it as a replace-the-word
    /// suggestion. `word` is the typo to replace; the accept path recomputes the edit from live text.
    case offerCorrection(word: String, correctedWord: String)
    /// The user finished a misspelled word with Space and enabled automatic fixing. Apply the edit
    /// immediately instead of creating an accept-key session.
    case applyCorrection(word: String, correctedWord: String)
}

enum TypoGate {
    /// The user settings that shape the gate decision, grouped so `resolve` takes one cohesive value
    /// instead of three loose Bools (which also keeps it within the parameter-count budget).
    struct Settings {
        let suppressCompletionsOnTypo: Bool
        let offerTypoCorrections: Bool
        let automaticallyFixTypos: Bool
    }

    /// Resolves the gate decision for the trailing word of `precedingText`.
    ///
    /// `isTypo` and `bestCorrection` are injected so this stays pure: in production they wrap
    /// `CurrentWordSpellChecker`; in tests they are stubs. Automatic fixing takes precedence only
    /// after a literal trailing Space. Before that boundary the gate may offer a correction, but never
    /// mutates an unfinished word merely because the user paused.
    static func resolve(
        precedingText: String,
        settings: Settings,
        isTypo: (String) -> Bool,
        bestCorrection: (String) -> String?
    ) -> TypoGateDecision {
        guard settings.suppressCompletionsOnTypo else {
            return .proceed
        }
        // Tolerate one trailing space so a just-finished word remains actionable: automatic mode can
        // apply it, while offer mode can keep the green correction alive after Space.
        guard let current = CurrentWordExtractor.extractTrailingWord(from: precedingText) else {
            return .proceed
        }
        guard isTypo(current.result.word) else {
            return .proceed
        }
        guard let corrected = bestCorrection(current.result.word) else {
            return .suppress
        }
        if settings.automaticallyFixTypos, current.trailingSpaceCount == 1 {
            return .applyCorrection(word: current.result.word, correctedWord: corrected)
        }
        if settings.offerTypoCorrections {
            return .offerCorrection(word: current.result.word, correctedWord: corrected)
        }
        return .suppress
    }
}
