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

    func test_consume_withNothingArmedLetsRealKeystrokesThrough() {
        let controller = InputSuppressionController()
        XCTAssertFalse(controller.consumeIfNeeded())

        // A negative count is clamped to zero rather than cancelling tokens already outstanding.
        controller.registerSyntheticInsertion(expectedKeyDownCount: 1)
        controller.registerSyntheticInsertion(expectedKeyDownCount: -3)
        XCTAssertTrue(controller.consumeIfNeeded())
        XCTAssertFalse(controller.consumeIfNeeded())
    }

    /// Production reads `Date()` directly, so the one-second expiry can only be crossed by waiting.
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

    /// The marker is drawn per launch, so it must never be the value real events carry (0) nor the
    /// constant earlier builds shipped, and it must stay the same for the life of the process so
    /// events marked before a lookup still match after it.
    func test_syntheticMarker_isNonzeroPerLaunchValue() {
        let marker = InputSuppressionController.syntheticEventUserData

        XCTAssertNotEqual(marker, 0)
        XCTAssertGreaterThan(marker, 0)
        XCTAssertNotEqual(marker, 0x436F_7461_6262_79, "The old compiled-in constant must not come back")
        XCTAssertEqual(InputSuppressionController.syntheticEventUserData, marker)
    }

    /// The identity rule: the marker must match, and the event must come from this process (or
    /// carry no source pid). Anything without the marker is ordinary input, whoever posted it.
    func test_syntheticSignature_requiresMarkerAndOwnOrUnsetSourcePID() {
        let marker: Int64 = 0x1234_5678_9ABC
        let ownPID: Int64 = 4242

        func matches(userData: Int64, sourcePID: Int64) -> Bool {
            InputSuppressionController.isSyntheticSignature(
                userData: userData, sourcePID: sourcePID, marker: marker, ownPID: ownPID
            )
        }

        XCTAssertTrue(matches(userData: marker, sourcePID: ownPID), "our own post")
        XCTAssertTrue(matches(userData: marker, sourcePID: 0), "our own post with no source pid")
        XCTAssertFalse(matches(userData: marker, sourcePID: 999), "the marker on another process's event")
        XCTAssertFalse(matches(userData: 0, sourcePID: 0), "a hardware keystroke")
        XCTAssertFalse(matches(userData: 0, sourcePID: 999), "a remapper's or automation tool's keystroke")
        XCTAssertFalse(matches(userData: marker + 1, sourcePID: ownPID), "a different marker")
        XCTAssertFalse(
            InputSuppressionController.isSyntheticSignature(userData: 0, sourcePID: ownPID, marker: 0, ownPID: ownPID),
            "0 is the value real events carry, so it can never act as a marker"
        )
    }
}
