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
        }
    }
}
