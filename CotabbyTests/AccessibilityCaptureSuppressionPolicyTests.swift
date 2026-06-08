import XCTest
@testable import Cotabby

final class AccessibilityCaptureSuppressionPolicyTests: XCTestCase {
    func testCalendarCaptureIsSuppressedByDefault() {
        XCTAssertTrue(
            AccessibilityCaptureSuppressionPolicy.shouldSuppressCapture(
                bundleIdentifier: "com.apple.iCal"
            )
        )
    }

    func testCalendarCaptureCanBeOverridden() {
        XCTAssertFalse(
            AccessibilityCaptureSuppressionPolicy.shouldSuppressCapture(
                bundleIdentifier: "com.apple.iCal",
                overrideBundleIdentifiers: ["com.apple.iCal"]
            )
        )
    }

    func testOrdinaryAppCaptureIsNotSuppressed() {
        XCTAssertFalse(
            AccessibilityCaptureSuppressionPolicy.shouldSuppressCapture(
                bundleIdentifier: "com.apple.Safari"
            )
        )
    }

    func testMissingBundleIdentifierIsNotSuppressed() {
        XCTAssertFalse(
            AccessibilityCaptureSuppressionPolicy.shouldSuppressCapture(bundleIdentifier: nil)
        )
    }
}
