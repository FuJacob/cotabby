import XCTest
@testable import Cotabby

/// Pins the screenshot/OCR budgets and the engine-to-profile privacy mapping.
final class VisualContextModelTests: XCTestCase {
    /// The on-device profile exists to read more of the screen than the profile a network endpoint
    /// gets, so every budget must be at least as large and only it may capture the whole window.
    func test_localConfiguration_isNeverNarrowerThanTheDefault() {
        let narrow = VisualContextConfiguration.default
        let wide = VisualContextConfiguration.local

        XCTAssertGreaterThanOrEqual(wide.maxImageDimension, narrow.maxImageDimension)
        XCTAssertGreaterThanOrEqual(wide.maxRecognizedCharacters, narrow.maxRecognizedCharacters)
        XCTAssertGreaterThanOrEqual(wide.maxSummaryCharacters, narrow.maxSummaryCharacters)
        XCTAssertTrue(wide.capturesEntireWindow)
        XCTAssertFalse(narrow.capturesEntireWindow)
    }

    func test_forEngine_keepsTheNetworkEndpointOnTheNarrowDefaultProfile() {
        // Choosing a network backend is not consent to send a wider screenshot's worth of text.
        XCTAssertEqual(VisualContextConfiguration.forEngine(.openAICompatible), .default)
        XCTAssertEqual(VisualContextConfiguration.forEngine(.appleIntelligence), .local)
        XCTAssertEqual(VisualContextConfiguration.forEngine(.llamaOpenSource), .local)
    }
}
