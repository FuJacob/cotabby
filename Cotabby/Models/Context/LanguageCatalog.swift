import Foundation

/// File overview:
/// Defines the languages Cotabby can be told the user writes in. Unlike a single "output language"
/// switch, this models the *set* of languages a user works across (e.g. a German/English
/// code-switcher) so the prompt can carry a soft hint instead of a hard override.
///
/// `commonLanguages` backs the tappable palette in `LanguageTagsEditor`; users can also add any
/// language as free text, so storage is `[String]` of language names rather than a closed enum.
/// `normalize` is the single chokepoint that keeps stored languages trimmed, de-duplicated, and
/// capped (mirroring `CustomRulesCatalog`). `promptInstruction(for:)` turns the stored set into the
/// hint the renderers inject; it deliberately never forces a language — it defers to the surrounding
/// text and only falls back to the declared languages when that text is too short to tell, which is
/// what protects mid-document code-switching while still steering cold-start completions.

/// One entry in the suggested-language palette.
struct LanguageOption: Identifiable, Equatable, Sendable {
    /// Legacy BCP-47-ish code, retained only so the one-time migration can map the previous
    /// single-select setting onto this list.
    let code: String
    /// Canonical English name. This is what we store and what goes into the prompt, because models
    /// follow "write in German" more reliably than a native-script label.
    let name: String
    /// Native-script label shown in the palette so a speaker recognizes their own language.
    let nativeLabel: String
    /// Average BPE tokens per orthographic "word" for the typical Llama/SentencePiece tokenizer.
    /// Drives the per-language max-token budget so a 7-word German continuation gets the longer
    /// budget German actually needs without bloating English requests. Numbers are approximate
    /// (corpus-dependent); when in doubt, bias slightly high so we clip less often than we overrun.
    let tokensPerWord: Double

    var id: String { code }
}

enum LanguageCatalog {
    /// Caps protect the prompt's context budget; few people actively write across more than a handful.
    static let maxLanguages = 6
    static let maxLanguageLength = 30

    /// Soft default applied on a clean install: pre-select English so the length budget has a
    /// language to anchor on out of the box. Users with a different primary language clear English
    /// and pick their own; multi-language users fall back to the English factor by design.
    static let defaultLanguages: [String] = ["English"]

    /// Tokens-per-word fallback when the user has no language selected, multiple languages selected,
    /// or a single language we don't have calibrated factors for. English-tokenizer-ish baseline,
    /// slightly above the empirical ~1.3 so the budget rarely truncates mid-word.
    static let fallbackTokensPerWord: Double = 1.3

    /// The tappable palette. Native labels help non-English speakers find their language; tapping a
    /// chip stores the English `name`. `code` matches the previous `SuggestionLanguage` raw values so
    /// the migration can map a persisted single choice onto this list. `tokensPerWord` values are
    /// rough Llama-tokenizer averages (Latin scripts cluster ~1.3-1.7, Cyrillic/Arabic/Devanagari
    /// closer to 2, CJK depends heavily on segmentation).
    static let commonLanguages: [LanguageOption] = [
        LanguageOption(code: "en", name: "English", nativeLabel: "English", tokensPerWord: 1.3),
        LanguageOption(code: "es", name: "Spanish", nativeLabel: "Español (Spanish)", tokensPerWord: 1.5),
        LanguageOption(code: "fr", name: "French", nativeLabel: "Français (French)", tokensPerWord: 1.5),
        LanguageOption(code: "de", name: "German", nativeLabel: "Deutsch (German)", tokensPerWord: 1.7),
        LanguageOption(code: "it", name: "Italian", nativeLabel: "Italiano (Italian)", tokensPerWord: 1.5),
        LanguageOption(code: "pt", name: "Portuguese", nativeLabel: "Português (Portuguese)", tokensPerWord: 1.5),
        LanguageOption(code: "nl", name: "Dutch", nativeLabel: "Nederlands (Dutch)", tokensPerWord: 1.6),
        LanguageOption(code: "ru", name: "Russian", nativeLabel: "Русский (Russian)", tokensPerWord: 2.0),
        LanguageOption(
            code: "zh-Hans",
            name: "Simplified Chinese",
            nativeLabel: "简体中文 (Simplified Chinese)",
            tokensPerWord: 1.2
        ),
        LanguageOption(code: "ja", name: "Japanese", nativeLabel: "日本語 (Japanese)", tokensPerWord: 1.8),
        LanguageOption(code: "ko", name: "Korean", nativeLabel: "한국어 (Korean)", tokensPerWord: 1.8),
        LanguageOption(code: "hi", name: "Hindi", nativeLabel: "हिन्दी (Hindi)", tokensPerWord: 2.0),
        LanguageOption(code: "ar", name: "Arabic", nativeLabel: "العربية (Arabic)", tokensPerWord: 2.0)
    ]

    /// Resolves the effective tokens-per-word multiplier for the user's declared language set.
    /// Returns the English fallback when no languages are declared, when more than one is declared
    /// (we can't safely pick between them), or when the single declared language isn't in the
    /// curated palette (typed in as free text). Only a single, recognized language wins its own
    /// calibrated factor — anything else gets the safe baseline.
    static func effectiveTokensPerWord(for languages: [String]) -> Double {
        let normalized = normalize(languages)
        guard normalized.count == 1,
              let only = normalized.first,
              let option = commonLanguages.first(where: { $0.name.caseInsensitiveCompare(only) == .orderedSame })
        else {
            return fallbackTokensPerWord
        }
        return option.tokensPerWord
    }

    /// Trims, drops empties, truncates over-long entries, de-duplicates case-insensitively (keeping
    /// the first occurrence and its original casing), and caps the count. The single place all
    /// language mutations pass through.
    static func normalize(_ languages: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for language in languages {
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let bounded = String(trimmed.prefix(maxLanguageLength))
            let key = bounded.lowercased()
            guard seen.insert(key).inserted else { continue }

            result.append(bounded)
            if result.count >= maxLanguages { break }
        }

        return result
    }

    /// Builds the soft language hint injected into both prompt backends, or `nil` when the user has
    /// declared no languages. The wording is intentionally non-forcing: match the surrounding text
    /// first, and only fall back to the declared languages when that text is too short or ambiguous
    /// to identify. That keeps a code-switcher's English text from being rewritten in German while
    /// still giving cold-start (empty-field) completions a sensible prior.
    static func promptInstruction(for languages: [String]) -> String? {
        let normalized = normalize(languages)
        guard !normalized.isEmpty else { return nil }

        let andList = formattedList(normalized, conjunction: "and")
        let orList = formattedList(normalized, conjunction: "or")
        return "The user usually writes in \(andList). Match the language of the text before the caret. "
            + "If that text is too short or ambiguous to tell, write in \(orList)."
    }

    /// Maps the previous single-select `SuggestionLanguage` raw value onto the new list. English was
    /// the old "no override" default, so it migrates to an empty set (no hint), preserving behavior;
    /// any other known code becomes that one language. Unknown codes migrate to empty.
    static func migratedLanguages(fromLegacyCode code: String) -> [String] {
        guard let option = commonLanguages.first(where: { $0.code == code }),
              option.code != "en" else {
            return []
        }
        return [option.name]
    }

    /// Joins names with commas and a final conjunction, using the Oxford comma for three or more
    /// (e.g. "German, English, and Spanish").
    private static func formattedList(_ items: [String], conjunction: String) -> String {
        switch items.count {
        case 0:
            return ""
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) \(conjunction) \(items[1])"
        default:
            let head = items.dropLast().joined(separator: ", ")
            return "\(head), \(conjunction) \(items[items.count - 1])"
        }
    }
}
