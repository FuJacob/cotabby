import XCTest
@testable import Cotabby

/// Tests for the "what's included" rows each onboarding template card discloses. The rows must stay
/// in lock-step with the template's own behavior flags, in a fixed order, for every tier (including
/// Custom, which the "Set up later" button applies without showing a card).
final class OnboardingTemplateFeatureListTests: XCTestCase {
    func test_rowsFollowEachTemplatesFlagsInDisplayOrder() {
        let expectedClipboard: [OnboardingTemplate: OnboardingTemplateFeatureValue] = [
            .quick: .disabled,
            .everyday: .enabled,
            .powerful: .enabled,
            .custom: .enabled
        ]
        for template in OnboardingTemplate.allCases {
            let rows = OnboardingTemplateFeatureList.rows(for: template)

            XCTAssertEqual(
                rows,
                [
                    OnboardingTemplateFeatureRow(
                        title: "Suggestion length",
                        value: .detail(template.wordCountPreset.displayLabel)
                    ),
                    // No tier turns on fast mode, so screen context is always shown as included.
                    OnboardingTemplateFeatureRow(title: "Use screen context", value: .enabled),
                    OnboardingTemplateFeatureRow(title: "Clipboard context", value: expectedClipboard[template]!)
                ],
                "\(template)"
            )
        }
    }

    func test_rowIdentityIsTheTitleAndUniqueWithinATemplate() {
        let rows = OnboardingTemplateFeatureList.rows(for: .everyday)
        XCTAssertEqual(rows.map(\.id), rows.map(\.title))
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }
}
