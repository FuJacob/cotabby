import XCTest
@testable import Cotabby

final class SpellingDictionaryResourceTests: XCTestCase {
    func test_everyCatalogDictionaryIsBundledAndParseable() throws {
        for language in SpellingDictionaryLanguage.allCases {
            let url = try XCTUnwrap(
                Bundle.main.url(
                    forResource: language.resourceName,
                    withExtension: "txt"
                ),
                "Missing bundled \(language.displayName) dictionary"
            )
            let firstLine = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", maxSplits: 1)
                .first
            let columns = firstLine?.split(whereSeparator: \.isWhitespace)

            XCTAssertEqual(columns?.count, 2, "Malformed \(language.displayName) dictionary")
            XCTAssertNotNil(columns.flatMap { Int64($0[1]) })
        }
    }
}

final class SpellingDictionaryLanguageMetadataTests: XCTestCase {
    func test_id_matchesPersistedISOCodeInStableCatalogOrder() {
        for language in SpellingDictionaryLanguage.allCases {
            XCTAssertEqual(language.id, language.rawValue)
        }
        // `SpellingDictionaryCatalog.normalize` emits codes in `allCases` order, so this order is a
        // persistence and rendering contract, not an implementation detail.
        XCTAssertEqual(
            SpellingDictionaryLanguage.allCases.map(\.rawValue),
            ["en", "de", "es", "fr", "he", "it", "ru"]
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
