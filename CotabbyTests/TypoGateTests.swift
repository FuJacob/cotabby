import XCTest
@testable import Cotabby

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

    func test_proceedsWhenSuppressionDisabled() {
        let decision = resolve(precedingText: "hi nmae", suppress: false, offer: true, typos: ["nmae"])
        XCTAssertEqual(decision, .proceed)
    }

    func test_proceedsWhenTrailingTokenIsNotAWord() {
        // A non-natural trailing token (digits/code) yields no actionable word even with a space, so
        // the gate proceeds regardless of the typo set. (A single trailing space alone no longer
        // suppresses the word — that is the point of Part A; see test_correctsWhenTypoFollowedByOneSpace.)
        let decision = resolve(precedingText: "ping 99 ", suppress: true, offer: true, typos: ["99"])
        XCTAssertEqual(decision, .proceed)
    }

    func test_proceedsWhenWordIsNotATypo() {
        let decision = resolve(precedingText: "hi name", suppress: true, offer: true, typos: ["nmae"])
        XCTAssertEqual(decision, .proceed)
    }

    func test_suppressesWhenTypoAndCorrectionsOff() {
        let decision = resolve(precedingText: "hi nmae", suppress: true, offer: false, typos: ["nmae"])
        XCTAssertEqual(decision, .suppress)
    }

    func test_suppressesWhenTypoButNoCorrectionAvailable() {
        // Corrections enabled, but the checker offered nothing usable: fall back to suppression.
        let decision = resolve(precedingText: "hi nmae", suppress: true, offer: true, typos: ["nmae"])
        XCTAssertEqual(decision, .suppress)
    }

    func test_correctsWhenTypoAndCorrectionAvailable() {
        let decision = resolve(
            precedingText: "hi my nmae",
            suppress: true,
            offer: true,
            typos: ["nmae"],
            corrections: ["nmae": "name"]
        )
        XCTAssertEqual(decision, .offerCorrection(word: "nmae", correctedWord: "name"))
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
        XCTAssertEqual(decision, .offerCorrection(word: "nmae", correctedWord: "name"))
    }
}
