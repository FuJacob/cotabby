import XCTest
@testable import Cotabby

/// Verifies the pure transition rules behind the coordinator's short post-acceptance Tab window.
/// Coordinator acceptance tests continue to cover the surrounding input-monitor and insertion effects.
@MainActor
final class PostExhaustionAcceptanceStateTests: XCTestCase {
    func test_armOpensFreshWindowAndInvalidatesPreviousBackstop() {
        var state = PostExhaustionAcceptanceState()
        let firstGeneration = state.arm()
        state.holdPressIfArmed()

        let secondGeneration = state.arm()

        XCTAssertTrue(state.isArmed)
        XCTAssertFalse(state.hasHeldPress)
        XCTAssertFalse(state.ownsBackstop(generation: firstGeneration))
        XCTAssertTrue(state.ownsBackstop(generation: secondGeneration))
    }

    func test_pressIsHeldOnlyWhileWindowIsArmed() {
        var state = PostExhaustionAcceptanceState()

        XCTAssertFalse(state.holdPressIfArmed())
        state.arm()
        XCTAssertTrue(state.holdPressIfArmed())
        XCTAssertTrue(state.holdPressIfArmed())
        XCTAssertTrue(state.hasHeldPress)
    }

    func test_clearClosesWindowAndInvalidatesCapturedBackstop() {
        var state = PostExhaustionAcceptanceState()
        let generation = state.arm()
        state.holdPressIfArmed()

        state.clear()

        XCTAssertFalse(state.isArmed)
        XCTAssertFalse(state.hasHeldPress)
        XCTAssertFalse(state.ownsBackstop(generation: generation))
    }

    func test_consumeHeldPressAtomicallyClosesWindow() {
        var heldState = PostExhaustionAcceptanceState()
        heldState.arm()
        heldState.holdPressIfArmed()

        XCTAssertTrue(heldState.consumeHeldPress())
        XCTAssertFalse(heldState.isArmed)

        var emptyState = PostExhaustionAcceptanceState()
        emptyState.arm()
        XCTAssertFalse(emptyState.consumeHeldPress())
        XCTAssertFalse(emptyState.isArmed)
    }

    func test_consumeInvalidatesTheCapturedBackstopAndClosesTheWindowForLaterPresses() {
        var state = PostExhaustionAcceptanceState()
        let generation = state.arm()
        state.holdPressIfArmed()

        XCTAssertTrue(state.consumeHeldPress())

        // The timeout scheduled by `arm()` is now stale, so it cannot release Tab ownership twice.
        XCTAssertFalse(state.ownsBackstop(generation: generation))
        // A press after the window closed belongs to the host, not to a closed window.
        XCTAssertFalse(state.holdPressIfArmed())
        // And consuming again cannot report the same held press twice.
        XCTAssertFalse(state.consumeHeldPress())
    }

    func test_consumeWithoutAnArmedWindowReportsNoHeldPress() {
        var state = PostExhaustionAcceptanceState()
        XCTAssertFalse(state.holdPressIfArmed())
        XCTAssertFalse(state.isArmed)
        XCTAssertFalse(state.consumeHeldPress())
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
