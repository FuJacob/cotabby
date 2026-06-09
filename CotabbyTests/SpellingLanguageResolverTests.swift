import XCTest
@testable import Cotabby

final class SpellingLanguageResolverTests: XCTestCase {
    private let resolver = SpellingLanguageResolver()

    func test_emptyEnabledSetReturnsNil() {
        XCTAssertNil(
            resolver.resolve(
                precedingText: "This is teh",
                currentWord: "teh",
                enabledLanguages: []
            )
        )
    }

    func test_singleEnabledLanguageUsesExplicitSelection() {
        XCTAssertEqual(
            resolver.resolve(
                precedingText: "ambiguous text bonjoru",
                currentWord: "bonjoru",
                enabledLanguages: [.french]
            ),
            .french
        )
    }

    func test_multilingualContextSelectsGerman() {
        XCTAssertEqual(
            resolver.resolve(
                precedingText: "Das ist ein kurzer deutscher Satz mit einem Feler",
                currentWord: "Feler",
                enabledLanguages: [.english, .german, .spanish]
            ),
            .german
        )
    }

    func test_multilingualContextSelectsSpanish() {
        XCTAssertEqual(
            resolver.resolve(
                precedingText: "Este es un texto breve escrito en españl",
                currentWord: "españl",
                enabledLanguages: [.english, .spanish, .french]
            ),
            .spanish
        )
    }

    func test_scriptDistinctWordCanResolveWithoutEarlierContext() {
        XCTAssertEqual(
            resolver.resolve(
                precedingText: "превет",
                currentWord: "превет",
                enabledLanguages: [.english, .russian]
            ),
            .russian
        )
    }

    func test_lowConfidenceHypothesisFallsBackToNativeSpellChecker() {
        XCTAssertNil(
            SpellingLanguageResolver.confidentLanguage(
                from: [.english: 0.46, .italian: 0.24, .spanish: 0.18]
            )
        )
    }
}
