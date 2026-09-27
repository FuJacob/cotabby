import XCTest
@testable import Cotabby

/// Tests for the pure suppress / offer / apply decision the typo gate makes before each prediction.
/// Spell-check behavior is stubbed, so each case pins one branch of the decision order.
final class TypoGateTests: XCTestCase {
    private func resolve(
        precedingText: String,
        suppress: Bool,
        offer: Bool,
        automatic: Bool = false,
        typos: Set<String> = [],
        corrections: [String: String] = [:]
    ) -> TypoGateDecision {
        TypoGate.resolve(
            precedingText: precedingText,
            settings: TypoGate.Settings(
                suppressCompletionsOnTypo: suppress,
                offerTypoCorrections: offer,
                automaticallyFixTypos: automatic
            ),
            isTypo: { typos.contains($0) },
            bestCorrection: { corrections[$0] }
        )
    }

    func test_pausedPrefixNeverCallsSpellingOrCorrection() {
        for prefix in ["wri", "becau", "recomm", "car"] {
            let decision = TypoGate.resolve(precedingText: "I typed " + prefix,
                settings: .init(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: true),
                isTypo: { _ in XCTFail("Unfinished words must not be spell-checked"); return true },
                bestCorrection: { _ in XCTFail("Unfinished words must not be corrected"); return "wrong" })
            XCTAssertEqual(decision, .proceed)
        }
    }

    func test_proceedsWhenSuppressionDisabled() {
        let decision = resolve(precedingText: "hi nmae", suppress: false, offer: true, typos: ["nmae"])
        XCTAssertEqual(decision, .proceed)
    }

    func test_proceedsWhenTrailingTokenIsNotAWord() {
        // A non-natural trailing token (digits/code) yields no actionable word even with a space, so
        // the gate proceeds regardless of the typo set.
        let decision = resolve(precedingText: "ping 99 ", suppress: true, offer: true, typos: ["99"])
        XCTAssertEqual(decision, .proceed)
    }

    func test_proceedsWhenCommittedWordIsNotATypo() {
        // The trailing space commits "name", so the gate does consult the checker; it just says no.
        var checkedWords: [String] = []
        let decision = TypoGate.resolve(
            precedingText: "hi name ",
            settings: .init(suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: false),
            isTypo: { checkedWords.append($0); return false },
            bestCorrection: { _ in XCTFail("A correctly spelled word must not be corrected"); return nil }
        )
        XCTAssertEqual(decision, .proceed)
        XCTAssertEqual(checkedWords, ["name"])
    }

    func test_suppressesWhenTypoAndCorrectionsOff() {
        let decision = resolve(precedingText: "hi nmae ", suppress: true, offer: false, typos: ["nmae"])
        XCTAssertEqual(decision, .suppress)
    }

    func test_suppressesWhenTypoButNoCorrectionAvailable() {
        // Corrections enabled, but the checker offered nothing usable: fall back to suppression.
        let decision = resolve(precedingText: "hi nmae ", suppress: true, offer: true, typos: ["nmae"])
        XCTAssertEqual(decision, .suppress)
    }

    func test_punctuationDelimiterOffersButNeverAutoApplies() {
        // A comma commits the word, but automatic fixing is reserved for a bare trailing space, so
        // the correction is offered instead of applied.
        let decision = resolve(
            precedingText: "hi my nmae,",
            suppress: true,
            offer: true,
            automatic: true,
            typos: ["nmae"],
            corrections: ["nmae": "name"]
        )
        XCTAssertEqual(decision, .offerCorrection(word: "nmae", correctedWord: "name"))
    }

    func test_automaticOnlyWithNonSpaceDelimiterSuppresses() {
        let decision = resolve(
            precedingText: "hi my nmae,",
            suppress: true,
            offer: false,
            automatic: true,
            typos: ["nmae"],
            corrections: ["nmae": "name"]
        )
        XCTAssertEqual(decision, .suppress)
    }

    func test_correctsWhenTypoFollowedByOneSpace() {
        // The correction must survive the user pressing space after the word.
        let decision = resolve(
            precedingText: "hi my nmae ",
            suppress: true,
            offer: true,
            typos: ["nmae"],
            corrections: ["nmae": "name"]
        )
        XCTAssertEqual(decision, .offerCorrection(word: "nmae", correctedWord: "name"))
    }

    func test_proceedsWhenTypoFollowedByTwoSpaces() {
        // Two spaces means the user moved on; no current word to correct.
        let decision = resolve(
            precedingText: "hi my nmae  ",
            suppress: true,
            offer: true,
            typos: ["nmae"],
            corrections: ["nmae": "name"]
        )
        XCTAssertEqual(decision, .proceed)
    }

    func test_automaticFixAppliesOnlyAfterSpace() {
        let decision = resolve(
            precedingText: "hi my nmae ",
            suppress: true,
            offer: false,
            automatic: true,
            typos: ["nmae"],
            corrections: ["nmae": "name"]
        )
        XCTAssertEqual(decision, .applyCorrection(word: "nmae", correctedWord: "name"))
    }

    func test_automaticFixDoesNotMutateUnfinishedWord() {
        let decision = resolve(
            precedingText: "hi my nmae",
            suppress: true,
            offer: true,
            automatic: true,
            typos: ["nmae"],
            corrections: ["nmae": "name"]
        )
        XCTAssertEqual(decision, .proceed)
    }
}
