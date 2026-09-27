import XCTest
@testable import Cotabby

/// Locks down the coordinator's extracted token-stream bookkeeping without involving an engine,
/// runloop timing, Accessibility, or overlay presentation.
@MainActor
final class SuggestionStreamingStateTests: XCTestCase {
    func test_enqueueCoalescesToNewestPartialAndSchedulesOnlyOneDrain() throws {
        var state = SuggestionStreamingState()
        let first = result(text: " wor")
        let newest = result(text: " world")

        XCTAssertTrue(state.enqueue(first, workID: 10))
        XCTAssertFalse(state.enqueue(newest, workID: 10))

        let pending = try XCTUnwrap(state.drain())
        XCTAssertEqual(pending.result, newest)
        XCTAssertEqual(pending.workID, 10)
        XCTAssertFalse(state.isDrainScheduled)
        XCTAssertNil(state.pendingPartial)
    }

    func test_beginGenerationPreservesScheduledDrainForReplacementPartial() throws {
        var state = SuggestionStreamingState()
        XCTAssertTrue(state.enqueue(result(text: " old"), workID: 1))

        state.recordRendered(" old")
        state.spellingAssessments["world"] = .known
        state.beginGeneration()

        XCTAssertNil(state.renderedText)
        XCTAssertNil(state.pendingPartial)
        XCTAssertTrue(state.spellingAssessments.isEmpty)
        XCTAssertTrue(state.isDrainScheduled)
        XCTAssertFalse(state.enqueue(result(text: " new"), workID: 2))

        let pending = try XCTUnwrap(state.drain())
        XCTAssertEqual(pending.result.text, " new")
        XCTAssertEqual(pending.workID, 2)
    }

    func test_clearSessionLetsAlreadyScheduledEmptyDrainSelfHeal() {
        var state = SuggestionStreamingState()
        state.enqueue(result(text: " pending"), workID: 4)
        state.recordRendered(" pending")
        state.spellingAssessments["wrold"] = .correctableTypo

        state.clearSession()

        XCTAssertNil(state.renderedText)
        XCTAssertNil(state.pendingPartial)
        XCTAssertTrue(state.spellingAssessments.isEmpty)
        XCTAssertTrue(state.isDrainScheduled)
        XCTAssertNil(state.drain())
        XCTAssertFalse(state.isDrainScheduled)
    }

    func test_renderedTextOnlyAdmitsStrictMonotonicExtensions() {
        var state = SuggestionStreamingState()

        XCTAssertTrue(state.canRender(" wor"))
        state.recordRendered(" wor")
        XCTAssertTrue(state.canRender(" world"))
        XCTAssertFalse(state.canRender(" wor"))
        XCTAssertFalse(state.canRender(" wild"))
    }

    func test_eachDrainReopensSchedulingForTheNextPartial() throws {
        var state = SuggestionStreamingState()
        XCTAssertNil(state.drain(), "a drain with nothing pending is harmless")
        XCTAssertFalse(state.isDrainScheduled)

        XCTAssertTrue(state.enqueue(result(text: " wor"), workID: 1))
        let drained = try XCTUnwrap(state.drain())
        XCTAssertEqual(drained.result.text, " wor")
        // Once the scheduled callback has run, the next partial needs a fresh drain.
        XCTAssertTrue(state.enqueue(result(text: " world"), workID: 1))
        XCTAssertTrue(state.isDrainScheduled)
    }

    func test_resetRenderedTextRebasesMonotonicityWithoutDroppingPendingWork() {
        // Typing through the ghost moves the anchor: the remaining tail is shorter than what was
        // rendered, yet it must be renderable at the new caret.
        var state = SuggestionStreamingState()
        state.enqueue(result(text: " world again"), workID: 3)
        state.recordRendered(" world again")
        XCTAssertFalse(state.canRender(" again"))

        state.resetRenderedText()

        XCTAssertNil(state.renderedText)
        XCTAssertTrue(state.canRender(" again"))
        XCTAssertTrue(state.isDrainScheduled)
        XCTAssertEqual(state.pendingPartial?.workID, 3)
        XCTAssertFalse(state.isFinalized)
    }

    func test_clearSessionRejectsLatePartialsUntilTheNextGeneration() {
        var state = SuggestionStreamingState()
        state.clearSession()
        XCTAssertTrue(state.isFinalized)
        XCTAssertFalse(state.enqueue(result(text: "late"), workID: 1))
        XCTAssertNil(state.pendingPartial)

        state.beginGeneration()
        XCTAssertFalse(state.isFinalized)
        XCTAssertTrue(state.enqueue(result(text: "fresh"), workID: 2))
    }

    func testFinalResultRejectsLatePartialsUntilTheNextGeneration() {
        var state = SuggestionStreamingState()
        state.enqueue(result(text: "late"), workID: 4)
        state.finishGeneration()
        XCTAssertNil(state.drain())
        XCTAssertFalse(state.enqueue(result(text: "later"), workID: 4))
        state.beginGeneration()
        XCTAssertTrue(state.enqueue(result(text: "new"), workID: 5))
    }

    private func result(text: String) -> SuggestionResult {
        SuggestionResult(
            generation: 7,
            rawText: text,
            text: text,
            latency: 0.01
        )
    }
}
