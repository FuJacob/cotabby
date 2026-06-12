import XCTest
@testable import Cotabby

/// Locks in that the seam guard fires only on the two failure shapes it exists for (fresh junk
/// punctuation runs, mid-word splices that misspell the joined word) and never on the ordinary
/// continuations that surround them. Every guard must fire rarely; most of these tests are
/// allow-cases for exactly that reason.
final class CompletionSeamGuardTests: XCTestCase {
    /// A stub dictionary: the listed words are known, everything else is a misspelling.
    private func knowing(_ words: Set<String>) -> (String) -> Bool {
        { words.contains($0.lowercased()) }
    }

    private let knowsEverything: (String) -> Bool = { _ in true }
    private let knowsNothing: (String) -> Bool = { _ in false }

    // MARK: - Junk punctuation runs

    func testFreshPunctuationRunIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Wait",
                completion: " what....",
                isKnownWord: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testSymbolRunIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Price: ",
                completion: "$$$$",
                isKnownWord: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testThreeCharacterRunIsAllowed() {
        // Ellipsis-length runs are ordinary prose.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Well",
                completion: "... maybe",
                isKnownWord: knowsEverything
            ),
            .allow
        )
    }

    func testSingleTrailingCharacterDoesNotExemptAJunkRun() {
        // "Hello." ends with one period; that must not license "...." from the completion. Only
        // a real preceding run (two or more) reads as a divider being extended.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Hello.",
                completion: "....",
                isKnownWord: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testStreamedPartialVariantAppliesOnlyTheJunkRule() {
        XCTAssertFalse(
            CompletionSeamGuard.allowsStreamedPartial(precedingText: "Wait", completion: " what....")
        )
        // A mid-word splice passes the streamed check; the spell half runs only on the final
        // apply, which replaces or suppresses whatever streamed.
        XCTAssertTrue(
            CompletionSeamGuard.allowsStreamedPartial(precedingText: "gre", completion: "atful and kind")
        )
    }

    func testContinuingAnExistingDividerIsAllowed() {
        // The user already has a dash run at the caret; extending it is intentional.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "----",
                completion: "------",
                isKnownWord: knowsEverything
            ),
            .allow
        )
    }

    func testFreshDividerAwayFromSeamIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "----",
                completion: " section ======",
                isKnownWord: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testRepeatedLettersAreNotJunk() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "That is so",
                completion: " coooool",
                isKnownWord: knowsEverything
            ),
            .allow
        )
    }

    // MARK: - Seam misspellings

    func testMisspelledSeamWordIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I am so gre",
                completion: "atful for this",
                isKnownWord: knowing(["great", "grateful"])
            ),
            .seamMisspelling(word: "greatful")
        )
    }

    func testKnownSeamWordIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I am so gre",
                completion: "at to hear it",
                isKnownWord: knowing(["great"])
            ),
            .allow
        )
    }

    func testSeamRuleOnlyAppliesMidWord() {
        // Caret after a space: no seam word exists, so nothing to judge.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I am so ",
                completion: "greatful",
                isKnownWord: knowsNothing
            ),
            .allow
        )
    }

    func testCapitalizedSeamWordIsAllowed() {
        // Names and brands are routinely out-of-dictionary; never block them.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Ask Cota",
                completion: "bby about it",
                isKnownWord: knowsNothing
            ),
            .allow
        )
    }

    func testShortSeamWordIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "a",
                completion: "t the office",
                isKnownWord: knowsNothing
            ),
            .allow
        )
    }

    func testDigitAdjacentSeamIsAllowed() {
        // The letter-run join is "vbeta"? No: digits break the letter run, so the head is empty
        // and the mid-word precondition (letter on both sides) fails.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "version 2",
                completion: "024 release",
                isKnownWord: knowsNothing
            ),
            .allow
        )
    }

    func testCJKSeamIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "これはとても良",
                completion: "い天気ですね",
                isKnownWord: knowsNothing
            ),
            .allow
        )
    }

    func testOrdinaryContinuationIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Thanks again for your help",
                completion: " with the move last weekend.",
                isKnownWord: knowing(["with"])
            ),
            .allow
        )
    }
}
