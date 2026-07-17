import Foundation

/// A bundled SymSpell frequency dictionary that Cotabby can use for ranked typo correction.
///
/// The raw value is the ISO 639-1 language code persisted in `UserDefaults`. Keeping the durable
/// representation as a standard language code makes future migrations straightforward and avoids
/// coupling stored preferences to display labels or resource filenames.
nonisolated enum SpellingDictionaryLanguage: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case hebrew = "he"
    case italian = "it"
    case russian = "ru"

    var id: String { rawValue }

    /// English name used in logs, documentation, and accessibility descriptions.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .hebrew: return "Hebrew"
        case .italian: return "Italian"
        case .russian: return "Russian"
        }
    }

    /// Native-script label shown in Settings so speakers can identify their language quickly.
    var settingsLabel: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch (German)"
        case .spanish: return "Español (Spanish)"
        case .french: return "Français (French)"
        case .hebrew: return "עברית (Hebrew)"
        case .italian: return "Italiano (Italian)"
        case .russian: return "Русский (Russian)"
        }
    }

    /// Resource basename from the upstream SymSpell frequency-dictionary folder.
    var resourceName: String {
        switch self {
        case .english: return "frequency_dictionary_en_82_765"
        case .german: return "de-100k"
        // Upstream ships the Spanish list as "es-100l" (letter "l", not the "k" every other language
        // uses); the bundled file is named es-100l.txt to match, so this divergence is intentional.
        case .spanish: return "es-100l"
        case .french: return "fr-100k"
        case .hebrew: return "he-100k"
        case .italian: return "it-100k"
        case .russian: return "ru-100k"
        }
    }
}

/// Pure catalog rules for the spelling-dictionary setting.
///
/// This is intentionally separate from `LanguageCatalog`: response languages steer model output,
/// while spelling dictionaries decide which deterministic correction indexes may be queried. A
/// multilingual writer may reasonably enable several response languages but keep autocorrection
/// limited to one conservative dictionary.
nonisolated enum SpellingDictionaryCatalog {
    static let defaultEnabledCodes = [SpellingDictionaryLanguage.english.rawValue]

    /// Drops unknown and duplicate codes, then returns the result in stable catalog order.
    ///
    /// Stable ordering keeps persisted values, snapshots, tests, and Settings rendering
    /// deterministic even when callers build the input from a `Set`.
    static func normalize(_ codes: [String]) -> [String] {
        let requested = Set(codes.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return SpellingDictionaryLanguage.allCases
            .filter { requested.contains($0.rawValue) }
            .map(\.rawValue)
    }

    static func languages(for codes: [String]) -> [SpellingDictionaryLanguage] {
        normalize(codes).compactMap(SpellingDictionaryLanguage.init(rawValue:))
    }
}
