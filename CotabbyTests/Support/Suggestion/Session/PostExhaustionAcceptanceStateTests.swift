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

    func test_consumeInvalidatesTheCapturedBackstopAndClosesTheWindowForLaterPresses() {
        var state = PostExhaustionAcceptanceState()
        let generation = state.arm()
        state.queueAcceptIfArmed()

        XCTAssertTrue(state.consumeQueuedAccept())

        // The timeout scheduled by `arm()` is now stale, so it cannot release Tab ownership twice.
        XCTAssertFalse(state.ownsBackstop(generation: generation))
        // A press after the regenerated accept belongs to the host, not to a closed window.
        XCTAssertFalse(state.queueAcceptIfArmed())
        // And consuming again cannot replay the single queued accept.
        XCTAssertFalse(state.consumeQueuedAccept())
    }

    func test_consumeWithoutAnArmedWindowNeverOwesAnAccept() {
        var state = PostExhaustionAcceptanceState()
        XCTAssertFalse(state.queueAcceptIfArmed())
        XCTAssertFalse(state.needsRelease)
        XCTAssertFalse(state.consumeQueuedAccept())
    }

    func test_generationsAreUniqueAcrossArmAndClearCycles() {
        // Every arm and every clear bumps the identity, so a timeout captured in any earlier cycle
        // can never be mistaken for the current one.
        var state = PostExhaustionAcceptanceState()
        var seen: Set<UInt64> = [state.backstopGeneration]
        for _ in 0..<3 {
            XCTAssertTrue(seen.insert(state.arm()).inserted)
            state.clear()
            XCTAssertTrue(seen.insert(state.backstopGeneration).inserted)
        }
        XCTAssertEqual(seen.count, 7)
    }
}
