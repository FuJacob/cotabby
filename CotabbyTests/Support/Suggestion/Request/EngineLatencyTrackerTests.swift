import XCTest
@testable import Cotabby

/// Verifies the latency memory that sizes the debounce: per-engine isolation, one first-text
/// sample per work item, and a median that a single slow request cannot move.
@MainActor
final class EngineLatencyTrackerTests: XCTestCase {
    func test_completionLatencyIsKeptPerEngine() {
        var tracker = EngineLatencyTracker()

        tracker.recordCompletion(milliseconds: 900, engine: .openAICompatible)
        tracker.recordCompletion(milliseconds: 40, engine: .llamaOpenSource)
        tracker.recordCompletion(milliseconds: 55, engine: .llamaOpenSource)

        XCTAssertEqual(tracker.lastCompletionMilliseconds, [.openAICompatible: 900, .llamaOpenSource: 55])
    }

    func test_typicalFirstTextIsNilUntilASampleExists() {
        var tracker = EngineLatencyTracker()
        XCTAssertNil(tracker.typicalFirstTextMilliseconds(engine: .llamaOpenSource))

        tracker.recordFirstText(milliseconds: 30, engine: .llamaOpenSource, workID: 1)

        XCTAssertEqual(tracker.typicalFirstTextMilliseconds(engine: .llamaOpenSource), 30)
        XCTAssertNil(tracker.typicalFirstTextMilliseconds(engine: .appleIntelligence))
    }

    func test_onlyTheFirstPartialOfAWorkItemIsSampled() {
        var tracker = EngineLatencyTracker()

        tracker.recordFirstText(milliseconds: 20, engine: .llamaOpenSource, workID: 7)
        tracker.recordFirstText(milliseconds: 400, engine: .llamaOpenSource, workID: 7)
        tracker.recordFirstText(milliseconds: 800, engine: .llamaOpenSource, workID: 7)

        XCTAssertEqual(tracker.typicalFirstTextMilliseconds(engine: .llamaOpenSource), 20)
    }

    func test_oneSlowRequestDoesNotMoveTheMedian() {
        var tracker = EngineLatencyTracker()

        tracker.recordFirstText(milliseconds: 20, engine: .llamaOpenSource, workID: 1)
        tracker.recordFirstText(milliseconds: 900, engine: .llamaOpenSource, workID: 2)
        tracker.recordFirstText(milliseconds: 25, engine: .llamaOpenSource, workID: 3)

        XCTAssertEqual(tracker.typicalFirstTextMilliseconds(engine: .llamaOpenSource), 25)
    }

    func test_twoSamplesReadTheSlowerOne() {
        var tracker = EngineLatencyTracker()

        tracker.recordFirstText(milliseconds: 20, engine: .llamaOpenSource, workID: 1)
        tracker.recordFirstText(milliseconds: 60, engine: .llamaOpenSource, workID: 2)

        XCTAssertEqual(tracker.typicalFirstTextMilliseconds(engine: .llamaOpenSource), 60)
    }

    func test_onlyTheMostRecentSamplesAreKept() {
        var tracker = EngineLatencyTracker()

        for (workID, milliseconds) in [(1, 900), (2, 900), (3, 10), (4, 20), (5, 30)] {
            tracker.recordFirstText(milliseconds: milliseconds, engine: .llamaOpenSource, workID: UInt64(workID))
        }

        XCTAssertEqual(tracker.typicalFirstTextMilliseconds(engine: .llamaOpenSource), 20)
    }
}
