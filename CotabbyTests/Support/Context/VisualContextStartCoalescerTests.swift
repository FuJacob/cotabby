import XCTest
@testable import Cotabby

/// Verifies the pure coalescing decision behind `VisualContextCoordinator.startSessionIfNeeded`.
/// This is the #280 fix: focus flapping (Chrome losing and re-acquiring the AX field) must not
/// restart the screenshot -> OCR -> cleanup pipeline on every flap.
final class VisualContextStartCoalescerTests: XCTestCase {
    private func id(_ element: String, _ sequence: UInt64) -> VisualContextFieldIdentity {
        VisualContextFieldIdentity(elementIdentifier: element, focusChangeSequence: sequence)
    }

    func test_decide_matrix() {
        let cases: [(
            name: String,
            incoming: VisualContextFieldIdentity,
            active: VisualContextFieldIdentity?,
            blocked: Bool,
            permission: Bool,
            pending: VisualContextFieldIdentity?,
            expected: VisualContextStartDecision
        )] = [
            ("nothing active or pending", id("field", 1), nil, false, true, nil, .start),
            ("same as active", id("field", 1), id("field", 1), false, true, nil, .ignore),
            // The flap case: the same field already waiting out its settle window must not re-arm.
            ("same as pending", id("field", 7), nil, false, true, id("field", 7), .ignore),
            ("pending matches while another field is active", id("field", 7), id("other", 3), false, true,
             id("field", 7), .ignore),
            // A bumped focus sequence on the same element is a new focus.
            ("same element, new sequence", id("field", 2), id("field", 1), false, true, id("other", 5), .start),
            // macOS recycles element hashes, so a matching sequence alone is not the same field.
            ("recycled sequence, different element", id("other", 1), id("field", 1), false, true, nil, .start),
            ("active blocked, permission granted", id("field", 1), id("field", 1), true, true, nil,
             .recoverPermissionThenStart),
            ("active blocked, permission missing", id("field", 1), id("field", 1), true, false, nil, .ignore),
            // Recovery applies only to the field that owns the blocked session.
            ("blocked session belongs to another field", id("new", 2), id("field", 1), true, true, nil, .start),
            ("pending match never recovers", id("field", 7), nil, true, true, id("field", 7), .ignore)
        ]
        for testCase in cases {
            XCTAssertEqual(
                VisualContextStartCoalescer.decide(
                    incoming: testCase.incoming,
                    active: testCase.active,
                    activeIsBlockedOnScreenRecording: testCase.blocked,
                    hasScreenRecordingPermission: testCase.permission,
                    pending: testCase.pending
                ),
                testCase.expected,
                testCase.name
            )
        }
    }
}
