import XCTest
@testable import Cotabby

/// Pins the permission metadata the onboarding, menu, and Settings permission rows render. The raw
/// values double as System Settings deep-link anchors, so they are a compatibility contract.
final class CotabbyPermissionKindTests: XCTestCase {

    func test_allCases_listsPermissionsInOnboardingOrderWithPrivacyAnchorRawValues() {
        XCTAssertEqual(CotabbyPermissionKind.allCases, [.accessibility, .inputMonitoring, .screenRecording])
        XCTAssertEqual(CotabbyPermissionKind.accessibility.rawValue, "Privacy_Accessibility")
        XCTAssertEqual(CotabbyPermissionKind.inputMonitoring.rawValue, "Privacy_ListenEvent")
        XCTAssertEqual(CotabbyPermissionKind.screenRecording.rawValue, "Privacy_ScreenCapture")
    }

    func test_settingsURL_usesExpectedDeepLinkFormat() {
        for kind in CotabbyPermissionKind.allCases {
            let expected = "x-apple.systempreferences:com.apple.preference.security?\(kind.rawValue)"
            XCTAssertEqual(kind.settingsURL.absoluteString, expected)
        }
    }

    func test_isRequiredForAutocomplete_isTrueOnlyForCoreInputPermissions() {
        XCTAssertTrue(CotabbyPermissionKind.accessibility.isRequiredForAutocomplete)
        XCTAssertTrue(CotabbyPermissionKind.inputMonitoring.isRequiredForAutocomplete)
        // Screen Recording is optional: missing it forces the text-only Fast Mode path rather than
        // disabling autocomplete.
        XCTAssertFalse(CotabbyPermissionKind.screenRecording.isRequiredForAutocomplete)
    }

    func test_isOptionalEnhancement_isTrueOnlyForScreenRecording() {
        XCTAssertTrue(CotabbyPermissionKind.screenRecording.isOptionalEnhancement)
        XCTAssertFalse(CotabbyPermissionKind.accessibility.isOptionalEnhancement)
        XCTAssertFalse(CotabbyPermissionKind.inputMonitoring.isOptionalEnhancement)
    }

    func test_compactRowTitle_appendsOptionalQualifierOnlyForEnhancements() {
        // Compact rows reuse the required rows' styling, so this suffix is the only thing that
        // marks Screen Recording as optional there.
        XCTAssertEqual(CotabbyPermissionKind.accessibility.compactRowTitle, "Accessibility")
        XCTAssertEqual(CotabbyPermissionKind.inputMonitoring.compactRowTitle, "Input Monitoring")
        XCTAssertEqual(CotabbyPermissionKind.screenRecording.compactRowTitle, "Screen Recording (Optional)")
    }
}

/// Guards the engine-to-profile privacy mapping for screenshot/OCR budgets.
final class VisualContextModelTests: XCTestCase {

    func test_defaultProfile_isNeverWiderThanTheLocalProfile() {
        // `.default` is what a network endpoint receives, so it must stay the narrow one: no
        // whole-window capture, and no budget larger than the on-device profile's.
        let narrow = VisualContextConfiguration.default
        let wide = VisualContextConfiguration.local
        XCTAssertFalse(narrow.capturesEntireWindow)
        XCTAssertLessThanOrEqual(narrow.maxImageDimension, wide.maxImageDimension)
        XCTAssertLessThanOrEqual(narrow.maxRecognizedCharacters, wide.maxRecognizedCharacters)
        XCTAssertLessThanOrEqual(narrow.maxSummaryCharacters, wide.maxSummaryCharacters)
    }

    func test_forEngine_keepsTheNetworkEndpointOnTheNarrowDefaultProfile() {
        // Choosing a network backend is not consent to send a wider screenshot's worth of text.
        XCTAssertEqual(VisualContextConfiguration.forEngine(.openAICompatible), .default)
        XCTAssertEqual(VisualContextConfiguration.forEngine(.appleIntelligence), .local)
        XCTAssertEqual(VisualContextConfiguration.forEngine(.llamaOpenSource), .local)
    }
}
