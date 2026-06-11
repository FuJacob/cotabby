import CoreGraphics
import XCTest
@testable import Cotabby

/// Locks the synthetic-keystroke suppression rules that keep Cotabby's own inserted text from
/// re-entering the input pipeline as "user typing". The regression these defend: rapid Tab
/// accepts arm suppression for the next chunk while the previous chunk's synthetic keydowns are
/// still in flight through the async event tap; an overwriting counter dropped the outstanding
/// tokens, a synthetic keydown leaked through classification, and the mismatch invalidated the
/// very suggestion being accepted.
@MainActor
final class InputSuppressionControllerTests: XCTestCase {
    func test_register_accumulatesAcrossRapidBursts() {
        let controller = InputSuppressionController()

        // Burst: chunk one arms three keydowns, one is observed, then chunk two arms two more
        // while chunk one's remaining two are still in flight.
        controller.registerSyntheticInsertion(expectedKeyDownCount: 3)
        XCTAssertTrue(controller.consumeIfNeeded())
        controller.registerSyntheticInsertion(expectedKeyDownCount: 2)

        // All four outstanding synthetic keydowns must still be covered.
        XCTAssertTrue(controller.consumeIfNeeded())
        XCTAssertTrue(controller.consumeIfNeeded())
        XCTAssertTrue(controller.consumeIfNeeded())
        XCTAssertTrue(controller.consumeIfNeeded())

        // And the first real keystroke after the burst must not be swallowed.
        XCTAssertFalse(controller.consumeIfNeeded())
    }

    func test_consume_expiryDropsStaleTokens() {
        let controller = InputSuppressionController()
        controller.registerSyntheticInsertion(expectedKeyDownCount: 5)

        // Stale tokens past the expiry window must not swallow later real keystrokes, and a
        // fresh arm after expiry must start from zero rather than stacking onto the stale count.
        let pastExpiry = Date().addingTimeInterval(1.1)
        while Date() < pastExpiry {
            usleep(50_000)
        }
        XCTAssertFalse(controller.consumeIfNeeded())

        controller.registerSyntheticInsertion(expectedKeyDownCount: 1)
        XCTAssertTrue(controller.consumeIfNeeded())
        XCTAssertFalse(controller.consumeIfNeeded())
    }

    func test_syntheticMarker_roundTripsThroughCGEvent() throws {
        let controller = InputSuppressionController()
        let marked = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        )
        let unmarked = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        )

        controller.markSynthetic(marked)

        XCTAssertTrue(controller.isSynthetic(marked))
        XCTAssertFalse(controller.isSynthetic(unmarked))
    }
}
