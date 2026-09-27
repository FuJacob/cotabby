import ApplicationServices
import XCTest
@testable import Cotabby

/// Tests for the pure suppression state transition that keeps Cotabby from collapsing Apple
/// Calendar's date/time editor: date/time controls enter suppression, editable text or another app
/// leaves it, and anything unrecognized holds the current state.
final class CalendarAccessibilityCapturePolicyTests: XCTestCase {
    private func suppress(
        currentlySuppressed: Bool,
        bundle: String? = CalendarAccessibilityCapturePolicy.calendarBundleIdentifier,
        role: String?,
        identifier: String?
    ) -> Bool {
        CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
            currentlySuppressed: currentlySuppressed,
            targetBundleIdentifier: bundle,
            targetRole: role,
            targetIdentifier: identifier
        )
    }

    func testEveryDateTimeControlIdentifierStartsSuppression() {
        for identifier in ["date-time-button", "start-datepicker", "start-timepicker", "end-datepicker", "end-timepicker"] {
            XCTAssertTrue(
                suppress(currentlySuppressed: false, role: kAXButtonRole as String, identifier: identifier),
                identifier
            )
        }
        XCTAssertTrue(suppress(currentlySuppressed: false, role: "AXDateTimeArea", identifier: nil))
    }

    func testEveryEditableTextRoleResumesCapture() {
        let roles = [kAXTextFieldRole as String, kAXTextAreaRole as String, "AXSearchField", kAXComboBoxRole as String]
        for role in roles {
            XCTAssertFalse(suppress(currentlySuppressed: true, role: role, identifier: nil), role)
        }
    }

    func testDateTimeIdentifierWinsOverAnEditableRole() {
        // A date picker that happens to expose a text-field role is still the fragile control.
        XCTAssertTrue(suppress(currentlySuppressed: false, role: kAXTextFieldRole as String, identifier: "start-timepicker"))
    }

    func testAnotherApplicationWinsEvenOverADateTimeTarget() {
        XCTAssertFalse(suppress(
            currentlySuppressed: true, bundle: "com.apple.TextEdit", role: "AXDateTimeArea", identifier: "date-time-button"
        ))
    }

    func testUnknownTargetWithoutPriorSuppressionStaysUnsuppressed() {
        XCTAssertFalse(suppress(currentlySuppressed: false, bundle: nil, role: nil, identifier: nil))
    }

    func testDateTimeAreaKeepsSuppressionActive() {
        XCTAssertTrue(
            CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
                currentlySuppressed: true,
                targetBundleIdentifier: "com.apple.iCal",
                targetRole: "AXDateTimeArea",
                targetIdentifier: "start-datepicker"
            )
        )
    }

    func testUnknownCalendarPickerControlKeepsExistingSuppression() {
        XCTAssertTrue(
            CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
                currentlySuppressed: true,
                targetBundleIdentifier: "com.apple.iCal",
                targetRole: kAXButtonRole as String,
                targetIdentifier: nil
            )
        )
    }

    func testAnotherApplicationClearsSuppression() {
        XCTAssertFalse(
            CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
                currentlySuppressed: true,
                targetBundleIdentifier: "com.apple.TextEdit",
                targetRole: kAXTextAreaRole as String,
                targetIdentifier: nil
            )
        )
    }

    func testUnresolvedOwnerBundleKeepsExistingSuppression() {
        // A nil bundle id means the AX owner lookup failed while Calendar is frontmost (the guard
        // already gated on that), not that the click left Calendar. Suppression must persist rather
        // than spuriously resume mid-edit and reintroduce the collapse bug.
        XCTAssertTrue(
            CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
                currentlySuppressed: true,
                targetBundleIdentifier: nil,
                targetRole: kAXButtonRole as String,
                targetIdentifier: nil
            )
        )
    }

    func testUnresolvedOwnerBundleStillResumesOnTextField() {
        // An editable role is an explicit safe boundary even when the owning bundle can't be read.
        XCTAssertFalse(
            CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
                currentlySuppressed: true,
                targetBundleIdentifier: nil,
                targetRole: kAXTextFieldRole as String,
                targetIdentifier: nil
            )
        )
    }

    func testOrdinaryCalendarClickDoesNotStartSuppression() {
        XCTAssertFalse(
            CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
                currentlySuppressed: false,
                targetBundleIdentifier: "com.apple.iCal",
                targetRole: kAXButtonRole as String,
                targetIdentifier: "today-button"
            )
        )
    }
}
