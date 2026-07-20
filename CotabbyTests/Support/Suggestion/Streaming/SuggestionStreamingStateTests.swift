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
        state.beginGeneration()

        XCTAssertNil(state.renderedText)
        XCTAssertNil(state.pendingPartial)
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

        state.clearSession()

        XCTAssertNil(state.renderedText)
        XCTAssertNil(state.pendingPartial)
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

    private func result(text: String) -> SuggestionResult {
        SuggestionResult(
            generation: 7,
            rawText: text,
            text: text,
            latency: 0.01
        )
    }
}
