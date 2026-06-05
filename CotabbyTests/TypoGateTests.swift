import XCTest
@testable import Cotabby

final class TypoGateTests: XCTestCase {
    private func resolve(
        precedingText: String,
        suppress: Bool,
        offer: Bool,
        typos: Set<String> = [],
        corrections: [String: String] = [:]
    ) -> TypoGateDecision {
        TypoGate.resolve(
            precedingText: precedingText,
            suppressCompletionsOnTypo: suppress,
            offerTypoCorrections: offer,
            isTypo: { typos.contains($0) },
            bestCorrection: { corrections[$0] }
        )
    }

    func test_proceedsWhenSuppressionDisabled() {
        let decision = resolve(precedingText: "hi nmae", suppress: false, offer: true, typos: ["nmae"])
        XCTAssertEqual(decision, .proceed)
    }

    func test_proceedsWhenNoCurrentWord() {
        // Trailing whitespace: no current word, so the gate never fires.
        let decision = resolve(precedingText: "hi nmae ", suppress: true, offer: true, typos: ["nmae"])
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
        XCTAssertEqual(decision, .correct(word: "nmae", correctedWord: "name"))
    }
}
