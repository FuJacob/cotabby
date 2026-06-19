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
