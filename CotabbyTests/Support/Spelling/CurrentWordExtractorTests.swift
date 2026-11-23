import XCTest
@testable import Cotabby

/// Tests for trailing-word extraction at the caret and the fail-closed typo replacement planner that
/// reuses it. Both feed destructive edits, so the rejection cases matter as much as the matches.
final class CurrentWordExtractorTests: XCTestCase {
    func test_extractsTrailingWordAtCaret() {
        XCTAssertEqual(CurrentWordExtractor.extract(from: "hi my nmae"), "nmae")
    }

    func test_returnsNilWhenCaretFollowsWhitespace() {
        // A trailing space means there is no "current word" the caret sits inside.
        XCTAssertNil(CurrentWordExtractor.extract(from: "hi my nmae "))
    }

    func test_returnsNilForEmptyText() {
        XCTAssertNil(CurrentWordExtractor.extract(from: ""))
    }

    func test_returnsNilForSingleCharacterWord() {
        // Single-letter tokens are too noisy to act on.
        XCTAssertNil(CurrentWordExtractor.extract(from: "a"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "I am a"))
    }

    func test_rejectsAllCapsAcronyms() {
        XCTAssertNil(CurrentWordExtractor.extract(from: "ship via HTTP"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "parse JSON"))
    }

    func test_rejectsTokensWithDigits() {
        XCTAssertNil(CurrentWordExtractor.extract(from: "build v2"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "room 101a"))
    }

    func test_rejectsCodeLikeTokens() {
        XCTAssertNil(CurrentWordExtractor.extract(from: "open https://example.com"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "call user_name"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "ping @jacob"))
        XCTAssertNil(CurrentWordExtractor.extract(from: "the file.swift"))
    }

    func test_acceptsMixedCaseNaturalWord() {
        XCTAssertEqual(CurrentWordExtractor.extract(from: "fix teh"), "teh")
        // Leading-capital natural words are fine; only ALL-caps tokens are rejected.
        XCTAssertEqual(CurrentWordExtractor.extract(from: "say Teh"), "Teh")
    }

    func test_wordBoundaryIsAnyWhitespace() {
        XCTAssertEqual(CurrentWordExtractor.extract(from: "line one\nteh"), "teh")
        XCTAssertEqual(CurrentWordExtractor.extract(from: "col\tteh"), "teh")
        XCTAssertEqual(CurrentWordExtractor.extract(from: "teh"), "teh")
    }

    func test_apostrophesHyphensAndTrailingProsePunctuationStayInTheToken() {
        XCTAssertEqual(CurrentWordExtractor.extract(from: "I didn't"), "didn't")
        XCTAssertEqual(CurrentWordExtractor.extract(from: "a well-knwon"), "well-knwon")
        // Trailing prose punctuation is not stripped here; the spell checker's whole-word range test
        // rejects it downstream (see `isPlausibleNaturalWord`).
        XCTAssertEqual(CurrentWordExtractor.extract(from: "hi nmae,"), "nmae,")
    }

    // MARK: - Typo replacement planning

    func test_typoReplacement_preservesCommittedSpaceAndUsesUTF16Count() {
        let replacement = TypoCorrectionReplacementPlanner.plan(
            precedingText: "hi my nmae ",
            expectedTypo: "nmae",
            correctedWord: "name",
            requiresTrailingSpace: true
        )

        XCTAssertEqual(
            replacement,
            TypoCorrectionReplacement(deletingUTF16Count: 5, replacementText: "name ")
        )
    }

    func test_typoReplacement_rejectsAutomaticFixBeforeSpace() {
        XCTAssertNil(
            TypoCorrectionReplacementPlanner.plan(
                precedingText: "hi my nmae",
                expectedTypo: "nmae",
                correctedWord: "name",
                requiresTrailingSpace: true
            )
        )
    }

    func test_typoReplacement_preservesPunctuationDelimiterWhenSpaceIsNotRequired() {
        XCTAssertEqual(
            TypoCorrectionReplacementPlanner.plan(
                precedingText: "hi my nmae, ",
                expectedTypo: "nmae",
                correctedWord: "name",
                requiresTrailingSpace: false
            ),
            TypoCorrectionReplacement(deletingUTF16Count: 6, replacementText: "name, ")
        )
        // Automatic fixes only fire on a bare trailing space, so ", " is refused there.
        XCTAssertNil(
            TypoCorrectionReplacementPlanner.plan(
                precedingText: "hi my nmae, ",
                expectedTypo: "nmae",
                correctedWord: "name",
                requiresTrailingSpace: true
            )
        )
    }

    func test_typoReplacement_trimsTheCorrection() {
        XCTAssertEqual(
            TypoCorrectionReplacementPlanner.plan(
                precedingText: "hi my nmae ",
                expectedTypo: "nmae",
                correctedWord: "  name\n",
                requiresTrailingSpace: true
            ),
            TypoCorrectionReplacement(deletingUTF16Count: 5, replacementText: "name ")
        )
    }

    func test_typoReplacement_rejectsBlankOrNoOpCorrections() {
        for correction in ["", "   ", "nmae"] {
            XCTAssertNil(
                TypoCorrectionReplacementPlanner.plan(
                    precedingText: "hi my nmae ",
                    expectedTypo: "nmae",
                    correctedWord: correction,
                    requiresTrailingSpace: false
                ),
                "correction \"\(correction)\""
            )
        }
    }

    func test_typoReplacement_rejectsChangedTrailingWord() {
        XCTAssertNil(
            TypoCorrectionReplacementPlanner.plan(
                precedingText: "hi my names ",
                expectedTypo: "nmae",
                correctedWord: "name",
                requiresTrailingSpace: false
            )
        )
    }
}
