import XCTest
@testable import Cotabby

/// Tests for choosing one enabled spelling dictionary from surrounding text. Recognizer-backed cases
/// use clearly monolingual samples; the confidence rule itself is tested through the pure
/// `confidentLanguage(from:)` seam so it does not depend on Natural Language model drift.
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

    func test_confidenceThresholdIsInclusive() {
        XCTAssertEqual(SpellingLanguageResolver.confidentLanguage(from: [.german: 0.55, .english: 0.45]), .german)
        XCTAssertNil(SpellingLanguageResolver.confidentLanguage(from: [.german: 0.549, .english: 0.451]))
    }

    func test_noScoresMeansNoLanguage() {
        XCTAssertNil(SpellingLanguageResolver.confidentLanguage(from: [:]))
    }

    func test_singleEnabledLanguageWinsEvenWithoutAnyText() {
        XCTAssertEqual(resolver.resolve(precedingText: "", currentWord: "", enabledLanguages: [.hebrew]), .hebrew)
    }

    func test_emptyContextWithMultipleEnabledLanguagesReturnsNil() {
        // With several dictionaries enabled and no text to sample, the resolver must not guess.
        XCTAssertNil(
            resolver.resolve(
                precedingText: "",
                currentWord: "",
                enabledLanguages: [.english, .german]
            )
        )
    }

    func test_currentWordNotAtEndOfContextStillResolvesFromFullContext() {
        // The typo is not the suffix of the preceding text (mid-edit correction), so the resolver
        // samples the whole preceding context instead of dropping a trailing word.
        XCTAssertEqual(
            resolver.resolve(
                precedingText: "Das ist ein kurzer deutscher Satz mit einem",
                currentWord: "Feler",
                enabledLanguages: [.english, .german, .spanish]
            ),
            .german
        )
    }
}
