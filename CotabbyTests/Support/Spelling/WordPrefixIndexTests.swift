import XCTest
@testable import Cotabby

final class WordPrefixIndexTests: XCTestCase {
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
