import XCTest
@testable import Cotabby

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

    func test_frequencyBreaksTiesAmongEquidistant() {
        // teh is one edit from the, ten, and tea; the most frequent (the) wins.
        let best = makeSymSpell().bestSuggestion(for: "teh")
        XCTAssertEqual(best?.term, "the")
    }

    func test_gibberishHasNoSuggestionWithinDistance() {
        XCTAssertNil(makeSymSpell().bestSuggestion(for: "qwxzy"))
    }

    func test_emptyDictionaryReturnsNil() {
        let symSpell = SymSpell()
        XCTAssertTrue(symSpell.isEmpty)
        XCTAssertNil(symSpell.bestSuggestion(for: "teh"))
    }

    func test_damerauOSADistances() {
        XCTAssertEqual(SymSpell.damerauOSA(Array("teh"), Array("the"), maxDistance: 2), 1)
        XCTAssertEqual(SymSpell.damerauOSA(Array("cat"), Array("cat"), maxDistance: 2), 0)
        XCTAssertEqual(SymSpell.damerauOSA(Array("kitten"), Array("sitten"), maxDistance: 2), 1)
        // Beyond the budget returns -1.
        XCTAssertEqual(SymSpell.damerauOSA(Array("abcdef"), Array("uvwxyz"), maxDistance: 2), -1)
    }
}
