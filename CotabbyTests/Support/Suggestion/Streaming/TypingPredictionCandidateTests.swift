import XCTest
@testable import Cotabby

/// Exercises the append-path proof independently of AX timing and inference speed.
final class TypingPredictionCandidateTests: XCTestCase {
    func testMatchingKeysTrimOnlyAfterExactHostPublication() {
        let source = snapshot("I'll send ")
        var candidate = candidate(source)
        let prediction = result("you the report tomorrow")
        XCTAssertTrue(candidate.receive(prediction, final: false))
        XCTAssertTrue(candidate.append("you ", in: source, at: 1))
        XCTAssertTrue(candidate.append("the ", in: source, at: 1.01))
        XCTAssertTrue(candidate.accepts(snapshot("I'll send you ")))
        XCTAssertNil(candidate.rebased(prediction, in: source, generation: 2))
        let rebased = candidate.rebased(prediction, in: snapshot("I'll send you the "), generation: 3)
        XCTAssertEqual(rebased?.text, "report tomorrow")
        XCTAssertEqual(rebased?.generation, 3)
    }

    func testUncoveredTypingHasOneBoundedGracePeriod() {
        let source = snapshot("I'll send ")
        var candidate = candidate(source)
        XCTAssertTrue(candidate.append("y", in: source, at: 1))
        XCTAssertTrue(candidate.append("o", in: source, at: 1.1))
        XCTAssertEqual(candidate.expiration(in: snapshot("I'll send yo")), 1.15)
        XCTAssertFalse(candidate.append("u", in: source, at: 1.16))
        XCTAssertTrue(candidate.receive(result("you the report"), final: false))
        XCTAssertNil(candidate.expiration(in: snapshot("I'll send yo")))
        XCTAssertTrue(candidate.append("u", in: snapshot("I'll send yo"), at: 1.17))
    }

    func testDivergenceAndFinalOutputBehindTypingCannotBeReused() {
        let source = snapshot("I'll send ")
        var candidate = candidate(source)
        XCTAssertTrue(candidate.append("y", in: source, at: 1))
        XCTAssertFalse(candidate.receive(result("everyone a copy"), final: false))
        XCTAssertFalse(candidate.receive(result(""), final: true))
        XCTAssertTrue(candidate.receive(result("you the report"), final: false))
        XCTAssertFalse(candidate.append("e", in: snapshot("I'll send y"), at: 1.01))
    }

    func testUnicodeUsesCharacterTrimmingAndUTF16CaretOffsets() {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Send ", selection: NSRange(location: 100, length: 0))
        var candidate = candidate(source)
        let prediction = result("🐹 café tomorrow")
        XCTAssertTrue(candidate.receive(prediction, final: false))
        XCTAssertTrue(candidate.append("🐹 ", in: source, at: 1))
        let published = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Send 🐹 ", selection: NSRange(location: 103, length: 0))
        XCTAssertEqual(candidate.rebased(prediction, in: published, generation: 2)?.text, "café tomorrow")
        XCTAssertFalse(candidate.accepts(CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Send 🐹 ", selection: NSRange(location: 102, length: 0))))
    }

    func testChangedFieldsSelectionSuffixAndUnobservedEditsFailClosed() {
        let source = snapshot("Hello ")
        let candidate = candidate(source)
        for changed in [
            CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "other", precedingText: "Hello "),
            CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 456, precedingText: "Hello "),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello ", focusChangeSequence: 2),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello ", trailingText: "edited"),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello ", selection: NSRange(location: 6, length: 1)),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello ", isSecure: true),
            snapshot("Hello x"), snapshot("Hell")
        ] {
            XCTAssertFalse(candidate.accepts(changed))
        }
    }

    func testControlKeysAndUnboundedTypingAreRejected() {
        let source = snapshot("Hello ")
        var candidate = candidate(source)
        for characters in ["", "\u{08}", "\n", "\t", String(repeating: "a", count: 65)] {
            XCTAssertFalse(candidate.append(characters, in: source, at: 1))
        }
        XCTAssertFalse(candidate.append("a", in: source, at: .infinity))
    }

    func testOldPartialsCannotRollBackTheCandidateOrOverwriteAFinal() {
        let source = snapshot("Hello ")
        var candidate = candidate(source)
        XCTAssertTrue(candidate.receive(result("world again"), final: false))
        XCTAssertTrue(candidate.receive(result("world"), final: false))
        XCTAssertEqual(candidate.latestResult?.text, "world again")
        XCTAssertTrue(candidate.receive(result("world again tomorrow"), final: true))
        XCTAssertFalse(candidate.receive(result("world again tomorrow morning"), final: false))
        XCTAssertFalse(candidate.append("everyone", in: source, at: 1))
    }

    private func snapshot(_ text: String) -> FocusedInputSnapshot {
        CotabbyTestFixtures.focusedInputSnapshot(precedingText: text)
    }

    private func candidate(_ source: FocusedInputSnapshot) -> TypingPredictionCandidate {
        TypingPredictionCandidate(context: FocusedInputContext(snapshot: source, generation: 1))
    }

    private func result(_ text: String) -> SuggestionResult {
        SuggestionResult(generation: 1, rawText: text, text: text, latency: 0.1)
    }
}
