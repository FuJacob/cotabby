import XCTest
@testable import Cotabby

/// Tests for the pure spelling-dictionary selection rules and the language list they draw from.
/// Normalization is the single chokepoint between whatever a caller hands in (a `Set`, hand-edited
/// defaults, an import) and the stable, catalog-ordered codes that are persisted and rendered.
final class SpellingDictionaryCatalogTests: XCTestCase {
    func test_normalize_trimsLowercasesDropsUnknownAndDuplicatesInCatalogOrder() {
        XCTAssertEqual(
            SpellingDictionaryCatalog.normalize([" RU ", "xx", "De", "ru", "EN"]),
            ["en", "de", "ru"]
        )
    }

    func test_normalize_emptyInputStaysEmpty() {
        // An explicitly empty selection means "NSSpellChecker only" and must not fall back to English.
        XCTAssertEqual(SpellingDictionaryCatalog.normalize([]), [])
    }

    func test_languages_mapsNormalizedCodesToCases() {
        XCTAssertEqual(SpellingDictionaryCatalog.languages(for: ["he", "FR", "bogus"]), [.french, .hebrew])
        XCTAssertEqual(SpellingDictionaryCatalog.defaultEnabledCodes, ["en"])
    }

    // MARK: - Language metadata

    func test_allCases_keepPersistedISOCodesInStableCatalogOrder() {
        // `SpellingDictionaryCatalog.normalize` emits codes in `allCases` order, so this order is a
        // persistence and rendering contract, not an implementation detail.
        XCTAssertEqual(
            SpellingDictionaryLanguage.allCases.map(\.rawValue),
            ["en", "de", "es", "fr", "he", "it", "ru", "tr", "mk"]
        )
    }

    func test_settingsLabel_includesEnglishNameForEveryLanguageAndStaysUnique() {
        let labels = SpellingDictionaryLanguage.allCases.map(\.settingsLabel)
        XCTAssertEqual(Set(labels).count, labels.count)

        for language in SpellingDictionaryLanguage.allCases {
            XCTAssertTrue(
                language.settingsLabel.contains(language.displayName),
                "\(language.rawValue) settings label should include the English name"
            )
        }

        XCTAssertEqual(SpellingDictionaryLanguage.english.settingsLabel, "English")
        XCTAssertEqual(SpellingDictionaryLanguage.german.settingsLabel, "Deutsch (German)")
        XCTAssertEqual(SpellingDictionaryLanguage.hebrew.settingsLabel, "עברית (Hebrew)")
    }
}
