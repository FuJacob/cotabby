import XCTest
@testable import Cotabby

/// Verifies the pure coalescing decision behind `VisualContextCoordinator.startSessionIfNeeded`.
/// This is the #280 fix: focus flapping (Chrome losing and re-acquiring the AX field) must not
/// restart the screenshot -> OCR -> summarize pipeline on every flap.
final class VisualContextStartCoalescerTests: XCTestCase {
    private func id(_ element: String, _ sequence: UInt64) -> VisualContextFieldIdentity {
        VisualContextFieldIdentity(elementIdentifier: element, focusChangeSequence: sequence)
    }

    func test_noActiveOrPending_starts() {
        XCTAssertEqual(
            VisualContextStartCoalescer.decide(
                incoming: id("field", 1), active: nil,
                activeIsBlockedOnScreenRecording: false,
                hasScreenRecordingPermission: true, pending: nil
            ),
            .start
        )
    }

    func test_sameAsActiveField_isIgnored() {
        XCTAssertEqual(
            VisualContextStartCoalescer.decide(
                incoming: id("field", 1), active: id("field", 1),
                activeIsBlockedOnScreenRecording: false,
                hasScreenRecordingPermission: true, pending: nil
            ),
            .ignore
        )
    }

    /// The flap case: the same field already waiting out its settle window must not re-arm.
    func test_sameAsPendingField_isIgnored() {
        XCTAssertEqual(
            VisualContextStartCoalescer.decide(
                incoming: id("field", 7), active: nil,
                activeIsBlockedOnScreenRecording: false,
                hasScreenRecordingPermission: true, pending: id("field", 7)
            ),
            .ignore
        )
    }

    /// A genuinely new field — or the same element with a bumped focus sequence — re-arms the capture.
    func test_differentField_starts() {
        XCTAssertEqual(
            VisualContextStartCoalescer.decide(
                incoming: id("field", 2), active: id("field", 1),
                activeIsBlockedOnScreenRecording: false,
                hasScreenRecordingPermission: true, pending: id("other", 5)
            ),
            .start
        )
    }

    func test_activeBlockedOnPermission_recoversWhenGranted() {
        XCTAssertEqual(
            VisualContextStartCoalescer.decide(
                incoming: id("field", 1), active: id("field", 1),
                activeIsBlockedOnScreenRecording: true,
                hasScreenRecordingPermission: true, pending: nil
            ),
            .recoverPermissionThenStart
        )
    }

    func test_activeBlockedButPermissionStillMissing_isIgnored() {
        XCTAssertEqual(
            VisualContextStartCoalescer.decide(
                incoming: id("field", 1), active: id("field", 1),
                activeIsBlockedOnScreenRecording: true,
                hasScreenRecordingPermission: false, pending: nil
            ),
            .ignore
        )
    }
}
