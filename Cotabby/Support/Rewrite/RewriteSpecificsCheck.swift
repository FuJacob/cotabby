import Foundation

/// File overview:
/// Finds the specifics a rewrite added: numbers and names that are not in the user's own text.
/// A rewrite goes out under the user's name, and a model asked to change the tone can still turn
/// "1000" into "100" or add a greeting with a name nobody wrote. The coordinator checks every
/// finished rewrite here; anything found turns plain Replace off and the preview says what changed
/// (`RewriteChangeWarning`). Pure, so what counts as a number or a name is pinned by tests.
nonisolated enum RewriteSpecificsCheck {
    /// The numbers and names in `rewrite` that `source` does not contain (empty: nothing added).
    /// Numbers compare by their digits, so "4.000" in the source covers "4000"; names compare
    /// ignoring case and diacritics, and a plural or possessive of a source name counts as the name.
    static func unsupportedSpecifics(in rewrite: String, source: String) -> [String] {
        let sourceNumbers = Set(numbers(in: source))
        let normalizedSource = normalized(source)
        var unsupported: [String] = []
        for number in numbers(in: rewrite) where !sourceNumbers.contains(number) {
            unsupported.append(number)
        }
        for name in properNames(in: rewrite)
        where !nameVariants(name).contains(where: { normalizedSource.contains(normalized($0)) }) {
            unsupported.append(name)
        }
        return unsupported
    }

    /// Digit runs with their separators removed ("4,000" → "4000", "3.5" → "35").
    static func numbers(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"\d[\d.,:]*\d|\d"#) else { return [] }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { text[$0].filter(\.isNumber) }
        }
    }

    /// Capitalized words that are not the first word of a sentence and not common sentence words:
    /// names of people, companies, places and products.
    static func properNames(in text: String) -> [String] {
        var names: [String] = []
        for sentence in sentences(text) {
            for word in sentence.split(whereSeparator: { $0.isWhitespace }).dropFirst() {
                let core = word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                guard let first = core.first, first.isUppercase, core.count > 1,
                      !commonCapitalized.contains(core.lowercased()) else { continue }
                // The part before an apostrophe: some languages attach suffixes to names that way.
                names.append(String(core.split(separator: "'").first ?? Substring(core)))
            }
        }
        return names
    }

    /// The name as written plus its base without an English plural or possessive ending.
    static func nameVariants(_ name: String) -> [String] {
        var variants = [name]
        for suffix in ["'s", "’s", "es", "s"] where name.count > suffix.count + 1 && name.hasSuffix(suffix) {
            variants.append(String(name.dropLast(suffix.count)))
        }
        return variants
    }

    /// Splits at line breaks and sentence-ending punctuation, so the first word of each sentence,
    /// which is capitalized anyway, is not mistaken for a name.
    private static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            if character.isNewline {
                sentences.append(current)
                current = ""
                continue
            }
            current.append(character)
            if ".!?؟".contains(character) {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)
        return sentences.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Words commonly capitalized mid-sentence that are not specifics to verify.
    private static let commonCapitalized: Set<String> = [
        "i", "i'm", "i'll", "i've", "i'd", "ok", "okay", "pm", "am", "eur", "usd", "tl", "try"
    ]
}
