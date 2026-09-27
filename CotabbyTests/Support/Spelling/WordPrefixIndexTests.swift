import XCTest
@testable import Cotabby

/// Tests for the exact-prefix vocabulary and the conservative word-completion fallback built on it.
/// The fallback must only ever append letters to what was typed, and must abstain when ambiguous.
final class WordPrefixIndexTests: XCTestCase {
    private typealias Candidate = WordPrefixIndex.Candidate

    func testCandidatesRankByFrequencyThenAlphabeticallyAndKeepTwo() {
        let index = WordPrefixIndex(contents: "schematic 8\nschema 100\nscheduled 10\nschedule 100\n")
        XCTAssertEqual(
            index.candidates(for: "sche"),
            [Candidate(word: "schedule", frequency: 100), Candidate(word: "schema", frequency: 100)]
        )
    }

    func testCandidatesExcludeTheExactWordAndIgnorePrefixCase() {
        let index = WordPrefixIndex(contents: "schedule 100\nscheduled 10\n")
        XCTAssertEqual(index.candidates(for: "SCHEDULE"), [Candidate(word: "scheduled", frequency: 10)])
    }

    func testIndexSkipsNonLetterAndNonPositiveEntries() {
        let index = WordPrefixIndex(contents: "don't 500\nabc1 400\nabcd 0\nabcde x\nabcdef 3\n")
        XCTAssertEqual(index.candidates(for: "abc"), [Candidate(word: "abcdef", frequency: 3)])
        XCTAssertTrue(index.candidates(for: "don").isEmpty)
    }

    func testDictionaryMarginIsInclusiveAtFourTimes() {
        let atMargin = [Candidate(word: "because", frequency: 400), Candidate(word: "becalm", frequency: 100)]
        XCTAssertEqual(WordCompletionFallback.suffix(for: "bec", references: [], dictionaryCandidates: atMargin), "ause")

        let belowMargin = [Candidate(word: "because", frequency: 399), Candidate(word: "becalm", frequency: 100)]
        XCTAssertNil(WordCompletionFallback.suffix(for: "bec", references: [], dictionaryCandidates: belowMargin))
    }

    func testAllCapsPrefixGetsAnUppercasedSuffix() {
        let candidates = [Candidate(word: "because", frequency: 100)]
        XCTAssertEqual(WordCompletionFallback.suffix(for: "BECAU", references: [], dictionaryCandidates: candidates), "SE")
    }

    func testReferencesDifferingOnlyInCaseCountAsOneSpelling() {
        XCTAssertEqual(
            WordCompletionFallback.suffix(for: "cota", references: ["Cotabby", "cotabby"], dictionaryCandidates: []),
            "bby"
        )
    }

    func testPrefixMustBeAtLeastThreeLetters() {
        let candidates = [Candidate(word: "because", frequency: 100)]
        XCTAssertNil(WordCompletionFallback.suffix(for: "be", references: [], dictionaryCandidates: candidates))
        XCTAssertNil(WordCompletionFallback.suffix(for: "be-c", references: [], dictionaryCandidates: candidates))
    }

    func testFallbackAppendsExactLettersAndRequiresAMargin() {
        let index = WordPrefixIndex(contents: "schedule 100\nscheduled 10\nschematic 8\nbeach 900\nbecause 100\n")
        XCTAssertEqual(WordCompletionFallback.suffix(for: "Schedu", references: [],
                                                   dictionaryCandidates: index.candidates(for: "Schedu")), "le")
        XCTAssertEqual(WordCompletionFallback.suffix(for: "becau", references: [],
                                                   dictionaryCandidates: index.candidates(for: "becau")), "se")
        let ambiguous = WordPrefixIndex(contents: "recommend 100\nrecombine 90\n")
        XCTAssertNil(WordCompletionFallback.suffix(for: "reco", references: [],
                                                 dictionaryCandidates: ambiguous.candidates(for: "reco")))
        XCTAssertTrue(index.candidates(for: "be").isEmpty)
    }

    func testReferenceVocabularySupportsNamesButNotAmbiguousGuesses() {
        let words = WordCompletionFallback.referenceWords(precedingText: "Cotabby helps. Use Cota", trailingText: "", glossary: "")
        XCTAssertFalse(words.contains("Cota"))
        XCTAssertEqual(WordCompletionFallback.suffix(for: "Cota", references: words, dictionaryCandidates: []), "bby")
        XCTAssertNil(WordCompletionFallback.suffix(for: "Cota", references: ["Cotabby", "Cotangent"], dictionaryCandidates: []))
        XCTAssertNil(WordCompletionFallback.suffix(for: "schedu", references: [], dictionaryCandidates: []))
    }
}
