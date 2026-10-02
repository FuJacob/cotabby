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

/// Turkish and Macedonian: the bundled lists, language selection, and Turkish casing rules.
final class TurkishMacedonianDictionaryTests: XCTestCase {
    private let resolver = SpellingLanguageResolver()

    func test_bundledListsStartWithEachLanguagesMostCommonWords() throws {
        func firstWords(_ language: SpellingDictionaryLanguage) throws -> [String] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: language.resourceName, withExtension: "txt"))
            return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").prefix(5)
                .map { String($0.split(separator: " ")[0]) }
        }
        XCTAssertEqual(try firstWords(.turkish).prefix(2), ["bir", "bu"])
        XCTAssertEqual(try firstWords(.macedonian).prefix(2), ["да", "не"])
    }

    func test_macedonianOnlyLettersSelectMacedonianOverRussian() {
        XCTAssertEqual(
            resolver.resolve(precedingText: "Ќе дојдам утре и ќе ви ја донесам ", currentWord: "кнјига",
                             enabledLanguages: [.russian, .macedonian]),
            .macedonian
        )
    }

    func test_russianOnlyLettersSelectRussianOverMacedonian() {
        XCTAssertEqual(
            resolver.resolve(precedingText: "Мы были в этом городе ещё вчера и ", currentWord: "видели",
                             enabledLanguages: [.russian, .macedonian]),
            .russian
        )
    }

    func test_turkishTextSelectsTurkishOverEnglish() {
        XCTAssertEqual(
            resolver.resolve(precedingText: "Bu cümleyi şimdi Türkçe yazıyorum ve yarın sana ", currentWord: "gönderecğim",
                             enabledLanguages: [.english, .turkish]),
            .turkish
        )
    }

    func test_turkishCapitalIRecasesWithTurkishRules() {
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "Isk", to: "ışık", locale: Locale(identifier: "tr")), "Işık")
        XCTAssertEqual(TypoCaseTransfer.applying(caseOf: "ISTNBUL", to: "istanbul", locale: Locale(identifier: "tr")), "İSTANBUL")
    }

    func test_turkishCorrectionMatchesACapitalizedTypo() {
        let corrector = SymSpellCorrector(preloadLanguage: nil)
        corrector.loadForTesting(contents: "ışık 500\nişık 1\n", language: .turkish)

        XCTAssertEqual(corrector.bestCorrection(for: "Işk", language: .turkish), "Işık")
    }

    func test_turkishPrefixLookupLowercasesDottedCapitalI() {
        let index = WordPrefixIndex(contents: "istanbul 900\nistasyon 100\n", locale: Locale(identifier: "tr"))

        XCTAssertEqual(index.candidates(for: "İsta").map(\.word), ["istanbul", "istasyon"])
    }
}
