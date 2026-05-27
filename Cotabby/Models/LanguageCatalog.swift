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

    var id: String { code }
}

enum LanguageCatalog {
    /// Caps protect the prompt's context budget; few people actively write across more than a handful.
    static let maxLanguages = 6
    static let maxLanguageLength = 30

    /// Empty = no declared languages. The editor's "Clear" restores this, and an empty set emits no
    /// prompt hint at all (the renderers then simply match the surrounding text).
    static let defaultLanguages: [String] = []

    /// The tappable palette. Native labels help non-English speakers find their language; tapping a
    /// chip stores the English `name`. `code` matches the previous `SuggestionLanguage` raw values so
    /// the migration can map a persisted single choice onto this list.
    static let commonLanguages: [LanguageOption] = [
        LanguageOption(code: "en", name: "English", nativeLabel: "English"),
        LanguageOption(code: "es", name: "Spanish", nativeLabel: "Español (Spanish)"),
        LanguageOption(code: "fr", name: "French", nativeLabel: "Français (French)"),
        LanguageOption(code: "de", name: "German", nativeLabel: "Deutsch (German)"),
        LanguageOption(code: "it", name: "Italian", nativeLabel: "Italiano (Italian)"),
        LanguageOption(code: "pt", name: "Portuguese", nativeLabel: "Português (Portuguese)"),
        LanguageOption(code: "nl", name: "Dutch", nativeLabel: "Nederlands (Dutch)"),
        LanguageOption(code: "ru", name: "Russian", nativeLabel: "Русский (Russian)"),
        LanguageOption(code: "zh-Hans", name: "Simplified Chinese", nativeLabel: "简体中文 (Simplified Chinese)"),
        LanguageOption(code: "ja", name: "Japanese", nativeLabel: "日本語 (Japanese)"),
        LanguageOption(code: "ko", name: "Korean", nativeLabel: "한국어 (Korean)"),
        LanguageOption(code: "hi", name: "Hindi", nativeLabel: "हिन्दी (Hindi)"),
        LanguageOption(code: "ar", name: "Arabic", nativeLabel: "العربية (Arabic)")
    ]

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
