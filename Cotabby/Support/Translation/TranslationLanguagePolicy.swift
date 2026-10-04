import Foundation
import NaturalLanguage

/// Decides which language a piece of text is in and whether it needs translating.
///
/// Pure apart from Apple's `NLLanguageRecognizer`, whose decision is wrapped by a deterministic
/// rule (`confidentLanguage`) so tests do not depend on Natural Language's model probabilities.
///
/// It is conservative on purpose: a wrong "this is Turkish" guess would put a nonsense
/// translation under a message, so short text, links, numbers, and low-confidence guesses are
/// left alone.
nonisolated enum TranslationLanguagePolicy {
    struct Detection: Equatable, Sendable {
        let language: String
        let confidence: Double
    }

    /// Below this many letters, language identification is guesswork ("ok", "haha", "👍").
    static let minimumLetters = 12
    static let minimumConfidence = 0.8

    /// The detected language of `text`, or nil when it is too short or ambiguous.
    static func detect(_ text: String) -> Detection? {
        let letters = text.filter(\.isLetter)
        guard letters.count >= minimumLetters, !looksLikeLinkOrCode(text) else { return nil }

        if let macedonian = macedonianByAlphabet(text) { return macedonian }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            .map { (code: $0.key.rawValue, score: $0.value) }
        guard let best = confidentLanguage(from: hypotheses) else { return nil }
        // Natural Language has no Macedonian model and labels Macedonian text Bulgarian. Text that
        // uses only letters the Macedonian alphabet has is far more likely Macedonian for a user
        // who writes it; genuine Bulgarian almost always uses ъ, щ, ь, ю or я.
        if best.language == "bg", usesOnlyMacedonianCyrillic(text) {
            return Detection(language: "mk", confidence: best.confidence)
        }
        return best
    }

    /// The detection when `text` should be translated into `readingLanguage`, else nil.
    static func needsTranslation(_ text: String, readingLanguage: String) -> Detection? {
        guard let detection = detect(text), !sameLanguage(detection.language, readingLanguage) else { return nil }
        return detection
    }

    /// Whether the user's draft is written in their reading language (the reply case).
    static func isWritten(in language: String, _ text: String) -> Bool {
        guard let detection = detect(text) else { return false }
        return sameLanguage(detection.language, language)
    }

    static func confidentLanguage(from hypotheses: [(code: String, score: Double)]) -> Detection? {
        guard let best = hypotheses.max(by: { $0.score < $1.score }), best.score >= minimumConfidence else { return nil }
        return Detection(language: best.code, confidence: best.score)
    }

    /// "en-US" and "en" are the same reading language.
    static func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        baseCode(lhs) == baseCode(rhs)
    }

    static func baseCode(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    // MARK: - Macedonian

    /// Letters only the Macedonian alphabet has (Serbian shares ј љ њ џ but not ѓ ќ ѕ).
    private static let macedonianOnlyLetters: Set<Character> = ["ѓ", "ќ", "ѕ"]
    /// Cyrillic letters absent from Macedonian (Russian, Bulgarian, Ukrainian).
    private static let nonMacedonianCyrillic: Set<Character> = ["ъ", "щ", "ь", "ю", "я", "ы", "э", "ё", "й", "і", "ї", "є"]

    private static func macedonianByAlphabet(_ text: String) -> Detection? {
        let lowered = text.lowercased()
        guard lowered.contains(where: macedonianOnlyLetters.contains),
              !lowered.contains(where: nonMacedonianCyrillic.contains) else { return nil }
        return Detection(language: "mk", confidence: 0.95)
    }

    private static func usesOnlyMacedonianCyrillic(_ text: String) -> Bool {
        !text.lowercased().contains(where: nonMacedonianCyrillic.contains)
    }

    // MARK: - Noise

    private static func looksLikeLinkOrCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("www.") { return true }
        // Mostly symbols and digits (codes, amounts, phone numbers): nothing to translate.
        let letters = trimmed.filter(\.isLetter).count
        return Double(letters) / Double(max(trimmed.count, 1)) < 0.5
    }
}
