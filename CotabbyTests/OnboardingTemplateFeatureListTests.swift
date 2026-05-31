import XCTest
@testable import Cotabby

final class OnboardingTemplateFeatureListTests: XCTestCase {
    func testQuickShowsShortLengthAndFastModeOnAndClipboardOff() {
        let rows = OnboardingTemplateFeatureList.rows(for: .quick)
        XCTAssertEqual(rows.map(\.title), [
            "Suggestion length",
            "Fast mode (skip screen context)",
            "Clipboard context"
        ])
        XCTAssertEqual(rows[0].value, .detail(OnboardingTemplate.quick.wordCountPreset.displayLabel))
        XCTAssertEqual(rows[1].value, .enabled)
        XCTAssertEqual(rows[2].value, .disabled)
    }

    func testEverydayShowsMediumLengthFastModeOffAndClipboardOn() {
        let rows = OnboardingTemplateFeatureList.rows(for: .everyday)
        XCTAssertEqual(rows[0].value, .detail(OnboardingTemplate.everyday.wordCountPreset.displayLabel))
        XCTAssertEqual(rows[1].value, .disabled)
        XCTAssertEqual(rows[2].value, .enabled)
    }

    func testPowerfulShowsLongLengthFastModeOffAndClipboardOn() {
        let rows = OnboardingTemplateFeatureList.rows(for: .powerful)
        XCTAssertEqual(rows[0].value, .detail(OnboardingTemplate.powerful.wordCountPreset.displayLabel))
        XCTAssertEqual(rows[1].value, .disabled)
        XCTAssertEqual(rows[2].value, .enabled)
    }
}
