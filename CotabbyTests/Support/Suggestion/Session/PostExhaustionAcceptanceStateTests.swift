import XCTest
@testable import Cotabby

/// Verifies the pure transition rules behind the coordinator's short post-acceptance Tab window.
/// Coordinator acceptance tests continue to cover the surrounding input-monitor and insertion effects.
@MainActor
final class PostExhaustionAcceptanceStateTests: XCTestCase {
    func test_armOpensFreshWindowAndInvalidatesPreviousBackstop() {
        var state = PostExhaustionAcceptanceState()
        let firstGeneration = state.arm()
        state.queueAcceptIfArmed()

        let secondGeneration = state.arm()

        XCTAssertTrue(state.isArmed)
        XCTAssertFalse(state.hasQueuedAccept)
        XCTAssertFalse(state.ownsBackstop(generation: firstGeneration))
        XCTAssertTrue(state.ownsBackstop(generation: secondGeneration))
    }

    func test_acceptQueuesOnlyWhileWindowIsArmed() {
        var state = PostExhaustionAcceptanceState()

        XCTAssertFalse(state.queueAcceptIfArmed())
        state.arm()
        XCTAssertTrue(state.queueAcceptIfArmed())
        XCTAssertTrue(state.queueAcceptIfArmed())
        XCTAssertTrue(state.hasQueuedAccept)
    }

    func test_clearClosesWindowAndInvalidatesCapturedBackstop() {
        var state = PostExhaustionAcceptanceState()
        let generation = state.arm()
        state.queueAcceptIfArmed()

        state.clear()

        XCTAssertFalse(state.isArmed)
        XCTAssertFalse(state.hasQueuedAccept)
        XCTAssertFalse(state.needsRelease)
        XCTAssertFalse(state.ownsBackstop(generation: generation))
    }

    func test_consumeQueuedAcceptAtomicallyClosesWindow() {
        var queuedState = PostExhaustionAcceptanceState()
        queuedState.arm()
        queuedState.queueAcceptIfArmed()

        XCTAssertTrue(queuedState.consumeQueuedAccept())
        XCTAssertFalse(queuedState.needsRelease)

        var emptyState = PostExhaustionAcceptanceState()
        emptyState.arm()
        XCTAssertFalse(emptyState.consumeQueuedAccept())
        XCTAssertFalse(emptyState.needsRelease)
    }
}
