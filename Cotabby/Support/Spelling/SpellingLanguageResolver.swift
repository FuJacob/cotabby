import Foundation
import NaturalLanguage

/// Selects one enabled spelling dictionary from the text surrounding the current typo.
///
/// The resolver is deliberately conservative. A wrong dictionary can produce a fluent but
/// destructive correction, while returning `nil` simply falls back to `NSSpellChecker`. When only
/// one dictionary is enabled, the user's explicit choice wins without detection. With several
/// enabled dictionaries, Natural Language must identify one with sufficient confidence.
nonisolated struct SpellingLanguageResolver: Sendable {
    /// Enough recent prose for reliable language identification without repeatedly scanning a large
    /// editor buffer on the typing path.
    private static let maximumContextCharacters = 800
    /// Short Latin-script words are often ambiguous across languages. Requiring a majority
    /// hypothesis keeps cases such as "hello" from selecting an arbitrary enabled dictionary.
    private static let minimumConfidence: Double = 0.55

    /// Returns the one enabled dictionary appropriate for `precedingText`, or `nil` when the
    /// language is ambiguous and native spell-check should rank the correction instead.
    func resolve(
        precedingText: String,
        currentWord: String,
        enabledLanguages: [SpellingDictionaryLanguage]
    ) -> SpellingDictionaryLanguage? {
        guard !enabledLanguages.isEmpty else {
            return nil
        }
        if enabledLanguages.count == 1 {
            return enabledLanguages[0]
        }

        let sample = Self.contextSample(precedingText: precedingText, currentWord: currentWord)
        guard !sample.isEmpty else {
            return nil
        }
        if let byLetters = Self.cyrillicLanguageByLetters(in: sample, enabledLanguages: enabledLanguages) {
            return byLetters
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = enabledLanguages.map(\.naturalLanguage)
        recognizer.processString(sample)

        let hypotheses = recognizer.languageHypotheses(withMaximum: enabledLanguages.count)
        let supportedScores = Dictionary(uniqueKeysWithValues: enabledLanguages.map {
            ($0, hypotheses[$0.naturalLanguage] ?? 0)
        })
        return Self.confidentLanguage(from: supportedScores)
    }

    /// Pure selection rule split from Apple's recognizer so confidence behavior can be tested
    /// deterministically even if Natural Language's model probabilities change between macOS releases.
    static func confidentLanguage(
        from scores: [SpellingDictionaryLanguage: Double]
    ) -> SpellingDictionaryLanguage? {
        guard let best = scores.max(by: { $0.value < $1.value }),
              best.value >= minimumConfidence else {
            return nil
        }
        return best.key
    }

    /// Macedonian and Russian share the Cyrillic script, and Natural Language has no Macedonian model
    /// (it labels Macedonian text Bulgarian). Letters that exist in only one of the two alphabets
    /// settle it without guessing: ѓ ќ ѕ ј љ њ џ are Macedonian, ы э ё щ ъ й are Russian. Only used
    /// when Macedonian is enabled, so every other combination keeps its existing detection.
    static func cyrillicLanguageByLetters(
        in sample: String,
        enabledLanguages: [SpellingDictionaryLanguage]
    ) -> SpellingDictionaryLanguage? {
        guard enabledLanguages.contains(.macedonian) else { return nil }
        let lowered = sample.lowercased()
        if lowered.contains(where: { macedonianOnlyLetters.contains($0) }) { return .macedonian }
        if enabledLanguages.contains(.russian), lowered.contains(where: { russianOnlyLetters.contains($0) }) {
            return .russian
        }
        return nil
    }

    private static let macedonianOnlyLetters: Set<Character> = ["ѓ", "ќ", "ѕ", "ј", "љ", "њ", "џ"]
    private static let russianOnlyLetters: Set<Character> = ["ы", "э", "ё", "щ", "ъ", "й"]

    /// Removes the known typo from the end so a malformed current word cannot outweigh the valid
    /// sentence before it. When no earlier context exists, the word itself remains useful for
    /// script-distinct languages such as Hebrew and Russian.
    private static func contextSample(precedingText: String, currentWord: String) -> String {
        let contextWithoutWord: Substring
        if precedingText.hasSuffix(currentWord) {
            contextWithoutWord = precedingText.dropLast(currentWord.count)
        } else {
            contextWithoutWord = precedingText[...]
        }

        let trimmedContext = contextWithoutWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedContext.isEmpty ? currentWord : trimmedContext
        return String(source.suffix(maximumContextCharacters))
    }
}

nonisolated private extension SpellingDictionaryLanguage {
    var naturalLanguage: NLLanguage {
        switch self {
        case .english: return .english
        case .german: return .german
        case .spanish: return .spanish
        case .french: return .french
        case .hebrew: return .hebrew
        case .italian: return .italian
        case .russian: return .russian
        case .turkish: return .turkish
        // Natural Language has no Macedonian model and reports Macedonian text as Bulgarian, so
        // Bulgarian stands in for it when Macedonian competes with other enabled dictionaries.
        case .macedonian: return .bulgarian
        }
    }
}
