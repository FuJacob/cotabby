import XCTest
@testable import Cotabby

/// Tests for the onboarding template card metadata. The recommender and feature-list rules have
/// their own suites; this one pins which tiers are offered as cards and what Custom promises.
final class OnboardingTemplateTests: XCTestCase {
    func test_curatedTiers_excludeCustomAndKeepDisplayOrder() {
        // Custom is applied by the "Set up later" button, never shown as a card.
        XCTAssertEqual(OnboardingTemplate.curatedTiers, [.quick, .everyday, .powerful])
        XCTAssertFalse(OnboardingTemplate.curatedTiers.contains(.custom))
    }

    func test_detail_customExplainsBothUserPopulations() {
        // Custom's copy must reassure returning users their tuned settings survive and point new
        // users at Settings for fine-tuning.
        XCTAssertTrue(OnboardingTemplate.custom.detail.contains("keep every setting"))
        XCTAssertTrue(OnboardingTemplate.custom.detail.contains("Settings"))
    }
}
