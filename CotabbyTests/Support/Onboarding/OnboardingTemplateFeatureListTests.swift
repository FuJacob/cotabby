import XCTest
@testable import Cotabby

final class OnboardingTemplateFeatureListTests: XCTestCase {
    func testQuickShowsShortLengthAndScreenContextOnAndClipboardOff() {
        let rows = OnboardingTemplateFeatureList.rows(for: .quick)
        XCTAssertEqual(rows.map(\.title), [
            "Suggestion length",
            "Use screen context",
            "Clipboard context"
        ])
        XCTAssertEqual(rows[0].value, .detail(OnboardingTemplate.quick.wordCountPreset.displayLabel))
        XCTAssertEqual(rows[1].value, .enabled)
        XCTAssertEqual(rows[2].value, .disabled)
    }

    func testEverydayShowsMediumLengthScreenContextOnAndClipboardOn() {
        let rows = OnboardingTemplateFeatureList.rows(for: .everyday)
        XCTAssertEqual(rows[0].value, .detail(OnboardingTemplate.everyday.wordCountPreset.displayLabel))
        XCTAssertEqual(rows[1].value, .enabled)
        XCTAssertEqual(rows[2].value, .enabled)
    }

    func testPowerfulShowsLongLengthScreenContextOnAndClipboardOn() {
        let rows = OnboardingTemplateFeatureList.rows(for: .powerful)
        XCTAssertEqual(rows[0].value, .detail(OnboardingTemplate.powerful.wordCountPreset.displayLabel))
        XCTAssertEqual(rows[1].value, .enabled)
        XCTAssertEqual(rows[2].value, .enabled)
    }
}
