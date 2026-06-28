import ApplicationServices
import XCTest
@testable import Cotabby

final class CalendarAccessibilityCapturePolicyTests: XCTestCase {
    func testDateTimeDisclosureStartsSuppression() {
        XCTAssertTrue(
            CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
                currentlySuppressed: false,
                targetBundleIdentifier: "com.apple.iCal",
                targetRole: kAXButtonRole as String,
                targetIdentifier: "date-time-button"
            )
        )
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

    func testCalendarTextFieldResumesCapture() {
        XCTAssertFalse(
            CalendarAccessibilityCapturePolicy.shouldSuppressCapture(
                currentlySuppressed: true,
                targetBundleIdentifier: "com.apple.iCal",
                targetRole: kAXTextFieldRole as String,
                targetIdentifier: "title-field"
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
