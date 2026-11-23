import XCTest
@testable import Cotabby

/// Pins the permission metadata the onboarding, menu, and Settings permission rows render. The raw
/// values double as System Settings deep-link anchors, so they are a compatibility contract.
final class CotabbyPermissionKindTests: XCTestCase {
    func test_allCases_listsPermissionsInOnboardingOrderWithPrivacyAnchorRawValues() {
        // No Input Monitoring: Accessibility already authorizes the keyboard event taps.
        XCTAssertEqual(CotabbyPermissionKind.allCases, [.accessibility, .screenRecording])
        XCTAssertEqual(CotabbyPermissionKind.accessibility.rawValue, "Privacy_Accessibility")
        XCTAssertEqual(CotabbyPermissionKind.screenRecording.rawValue, "Privacy_ScreenCapture")
    }

    func test_isRequiredForAutocomplete_isTrueOnlyForCoreInputPermissions() {
        XCTAssertTrue(CotabbyPermissionKind.accessibility.isRequiredForAutocomplete)
        // Screen Recording is optional: missing it forces the text-only Fast Mode path rather than
        // disabling autocomplete.
        XCTAssertFalse(CotabbyPermissionKind.screenRecording.isRequiredForAutocomplete)
    }

    func test_isOptionalEnhancement_isTrueOnlyForScreenRecording() {
        XCTAssertTrue(CotabbyPermissionKind.screenRecording.isOptionalEnhancement)
        XCTAssertFalse(CotabbyPermissionKind.accessibility.isOptionalEnhancement)
    }

    func test_compactRowTitle_appendsOptionalQualifierOnlyForEnhancements() {
        // Compact rows reuse the required rows' styling, so this suffix is the only thing that
        // marks Screen Recording as optional there.
        XCTAssertEqual(CotabbyPermissionKind.accessibility.compactRowTitle, "Accessibility")
        XCTAssertEqual(CotabbyPermissionKind.screenRecording.compactRowTitle, "Screen Recording (Optional)")
    }
}
