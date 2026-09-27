import XCTest
@testable import Cotabby

/// Tests for the in-repo SymSpell port: dictionary loading, lookup ranking, and the bounded
/// Damerau-OSA distance that verifies every candidate.
final class SymSpellTests: XCTestCase {
    private func makeSymSpell() -> SymSpell {
        let symSpell = SymSpell(maxDictionaryEditDistance: 2, prefixLength: 7)
        // word<space>count, like the SymSpell frequency dictionary format.
        symSpell.loadDictionary(contents: """
        the 1000000
        because 90000
        name 50000
        ten 20000
        tea 15000
        receive 8000
        definitely 6000
        separate 4000
        occurred 3000
        their 70000
        there 80000
        """)
        return symSpell
    }

    func test_exactMatchReturnsZeroDistance() {
        let best = makeSymSpell().bestSuggestion(for: "name")
        XCTAssertEqual(best?.term, "name")
        XCTAssertEqual(best?.distance, 0)
    }

    func test_transpositionIsDistanceOne() {
        // teh -> the via a single adjacent transposition.
        let best = makeSymSpell().bestSuggestion(for: "teh")
        XCTAssertEqual(best?.term, "the")
        XCTAssertEqual(best?.distance, 1)
    }

    func test_correctsCommonMisspellings() {
        let symSpell = makeSymSpell()
        XCTAssertEqual(symSpell.bestSuggestion(for: "recieve")?.term, "receive")
        XCTAssertEqual(symSpell.bestSuggestion(for: "becuase")?.term, "because")
        XCTAssertEqual(symSpell.bestSuggestion(for: "definately")?.term, "definitely")
        XCTAssertEqual(symSpell.bestSuggestion(for: "seperate")?.term, "separate")
        XCTAssertEqual(symSpell.bestSuggestion(for: "occured")?.term, "occurred")
    }

    func test_lookupSortsByDistanceThenFrequency() {
        let symSpell = SymSpell()
        symSpell.loadDictionary(contents: "cat 10\ncart 50\ncoat 30\nact 5\n")

        // "caat" is one edit from cat, cart, and coat and two from act; within a distance the more
        // frequent word leads.
        let suggestions = symSpell.lookup("caat")
        XCTAssertEqual(suggestions.map(\.term), ["cart", "coat", "cat", "act"])
        XCTAssertEqual(suggestions.map(\.distance), [1, 1, 1, 2])
        XCTAssertEqual(suggestions.first?.count, 50)
    }

    func test_lookupHonorsANarrowerEditDistanceButNeverAWiderOne() {
        let symSpell = SymSpell(maxDictionaryEditDistance: 2)
        symSpell.loadDictionary(contents: "cat 10\ncart 50\ncoat 30\nact 5\n")

        XCTAssertEqual(symSpell.lookup("caat", maxEditDistance: 1).map(\.term), ["cart", "coat", "cat"])
        // A request above the index's build distance is capped at it.
        XCTAssertEqual(symSpell.lookup("caat", maxEditDistance: 5).map(\.term), ["cart", "coat", "cat", "act"])
        XCTAssertEqual(symSpell.lookup("cat", maxEditDistance: 0), [SymSpellSuggestion(term: "cat", distance: 0, count: 10)])
        XCTAssertTrue(symSpell.lookup("caat", maxEditDistance: 0).isEmpty)
    }

    func test_inputFarLongerThanAnyDictionaryWordShortCircuits() {
        let symSpell = SymSpell()
        symSpell.loadDictionary(contents: "cat 10\n")
        XCTAssertTrue(symSpell.lookup("catastrophe").isEmpty)
    }

    func test_loadDictionarySkipsMalformedLinesAndAcceptsTabs() {
        let symSpell = SymSpell()
        symSpell.loadDictionary(contents: "lonely\nword notanumber\nzero 0\nnegative -3\ntabbed\t7\n\nspaced 9 extra\n")

        XCTAssertEqual(symSpell.wordCount, 2)
        XCTAssertEqual(symSpell.bestSuggestion(for: "tabbed"), SymSpellSuggestion(term: "tabbed", distance: 0, count: 7))
        XCTAssertEqual(symSpell.bestSuggestion(for: "spaced")?.count, 9)
    }

    func test_duplicateEntryKeepsTheFirstCount() {
        let symSpell = SymSpell()
        symSpell.createDictionaryEntry(key: "cat", count: 10)
        symSpell.createDictionaryEntry(key: "cat", count: 999)

        XCTAssertEqual(symSpell.wordCount, 1)
        XCTAssertEqual(symSpell.bestSuggestion(for: "cat")?.count, 10)
    }

    func test_gibberishHasNoSuggestionWithinDistance() {
        XCTAssertNil(makeSymSpell().bestSuggestion(for: "qwxzy"))
    }

    func test_emptyDictionaryReturnsNil() {
        let symSpell = SymSpell()
        XCTAssertEqual(symSpell.wordCount, 0)
        XCTAssertNil(symSpell.bestSuggestion(for: "teh"))
    }

    func test_damerauOSADistances() {
        XCTAssertEqual(SymSpell.damerauOSA(Array("teh"), Array("the"), maxDistance: 2), 1)
        XCTAssertEqual(SymSpell.damerauOSA(Array("cat"), Array("cat"), maxDistance: 2), 0)
        XCTAssertEqual(SymSpell.damerauOSA(Array("kitten"), Array("sitten"), maxDistance: 2), 1)
        // Beyond the budget returns -1.
        XCTAssertEqual(SymSpell.damerauOSA(Array("abcdef"), Array("uvwxyz"), maxDistance: 2), -1)
    }

    func test_damerauOSA_emptyAndLengthGapEdges() {
        XCTAssertEqual(SymSpell.damerauOSA([], Array("ab"), maxDistance: 2), 2)
        XCTAssertEqual(SymSpell.damerauOSA(Array("abc"), [], maxDistance: 2), -1)
        // A length gap larger than the budget is rejected before building the matrix.
        XCTAssertEqual(SymSpell.damerauOSA(Array("a"), Array("abcd"), maxDistance: 2), -1)
        // Exactly at the budget still counts.
        XCTAssertEqual(SymSpell.damerauOSA(Array("ab"), Array("abcd"), maxDistance: 2), 2)
    }
}
