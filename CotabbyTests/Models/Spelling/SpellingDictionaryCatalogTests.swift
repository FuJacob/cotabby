import XCTest
@testable import Cotabby

/// Tests for the pure spelling-dictionary selection rules. Normalization is the single chokepoint
/// between whatever a caller hands in (a `Set`, hand-edited defaults, an import) and the stable,
/// catalog-ordered codes that are persisted and rendered.
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
}
