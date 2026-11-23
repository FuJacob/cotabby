import XCTest
@testable import Cotabby

/// Verifies the two independent progressions of a prepared continuation: the source word being
/// committed and then published, and the request producing its answer.
@MainActor
final class PreparedContinuationTests: XCTestCase {
    private func makePrepared() throws -> PreparedContinuation {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu")
        let plan = try XCTUnwrap(SuggestionContinuationPlan.completing("le", in: source))
        let session = ActiveSuggestionSession(
            baseContext: FocusedInputContext(snapshot: source, generation: 1), fullText: "le", latency: 0
        )
        return PreparedContinuation(plan: plan, sourceSession: session)
    }

    func test_startsRunningWithItsSourceStillVisible() throws {
        let prepared = try makePrepared()

        XCTAssertEqual(prepared.commitment, .sourceVisible)
        XCTAssertEqual(prepared.answer, .running)
        XCTAssertFalse(prepared.isCommitted)
        XCTAssertFalse(prepared.ownsNextPrediction)
        XCTAssertNil(prepared.readyText)
    }

    func test_targetPublicationCountsOnlyAfterTheSourceIsCommitted() throws {
        var prepared = try makePrepared()

        prepared.markTargetPublished()
        XCTAssertEqual(prepared.commitment, .sourceVisible, "The same text on screen is still only the offer")

        prepared.markCommitted()
        XCTAssertTrue(prepared.isCommitted)
        XCTAssertFalse(prepared.ownsNextPrediction)

        prepared.markTargetPublished()
        XCTAssertEqual(prepared.commitment, .committed(targetPublished: true))
        XCTAssertTrue(prepared.ownsNextPrediction)
    }

    func test_committingAgainKeepsThePublishedTarget() throws {
        var prepared = try makePrepared()
        prepared.markCommitted()
        prepared.markTargetPublished()

        prepared.markCommitted()

        XCTAssertTrue(prepared.ownsNextPrediction)
    }

    func test_answerArrivesIndependentlyOfCommitment() throws {
        var prepared = try makePrepared()

        prepared.receive(text: " the meeting", latency: 0.2)
        XCTAssertEqual(prepared.answer, .ready(text: " the meeting", latency: 0.2))
        XCTAssertEqual(prepared.readyText, " the meeting")
        XCTAssertFalse(prepared.isCommitted)

        prepared.markCommitted()
        prepared.markTargetPublished()
        XCTAssertEqual(prepared.readyText, " the meeting")
        XCTAssertTrue(prepared.ownsNextPrediction)
    }

    func test_awaitsItsTargetOnlyOnceCommittedAndOnlyInItsSourceField() throws {
        var prepared = try makePrepared()
        let sameField = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedule ")
        let otherField = CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "other-field", precedingText: "Please schedule "
        )

        XCTAssertFalse(prepared.awaitsTarget(in: sameField), "An uncommitted source is still only the offer")

        prepared.markCommitted()
        XCTAssertTrue(prepared.awaitsTarget(in: sameField))
        XCTAssertFalse(prepared.awaitsTarget(in: otherField), "A field switch is not the target arriving")
        XCTAssertFalse(prepared.awaitsTarget(in: nil))
    }

    func test_belongsOnlyToTheSessionItWasPreparedFor() throws {
        let prepared = try makePrepared()
        let source = prepared.sourceSession

        XCTAssertTrue(prepared.belongs(to: source))
        XCTAssertTrue(prepared.belongs(to: source.advancing(by: 1)), "Consuming the source word keeps its identity")
        XCTAssertFalse(prepared.belongs(to: ActiveSuggestionSession(
            baseContext: source.baseContext, fullText: "led", latency: 0
        )))
        XCTAssertFalse(prepared.belongs(to: ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(precedingText: "Please schedu", generation: 2),
            fullText: "le", latency: 0
        )))
    }
}
