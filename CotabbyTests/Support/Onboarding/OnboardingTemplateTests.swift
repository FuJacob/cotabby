import XCTest
@testable import Cotabby

/// Tests for the onboarding template card metadata. The recommender and feature-list rules have
/// their own suites; this one pins the per-tier identity, copy, and icons the cards render.
final class OnboardingTemplateTests: XCTestCase {
    func test_id_matchesRawValueForEveryTemplate() {
        for template in OnboardingTemplate.allCases {
            XCTAssertEqual(template.id, template.rawValue)
        }
    }

    func test_curatedTiers_excludeCustomAndKeepDisplayOrder() {
        // Custom is applied by the "Set up later" button, never shown as a card.
        XCTAssertEqual(OnboardingTemplate.curatedTiers, [.quick, .everyday, .powerful])
        XCTAssertFalse(OnboardingTemplate.curatedTiers.contains(.custom))
    }

    func test_title_isThePinnedCardNamePerTier() {
        XCTAssertEqual(OnboardingTemplate.quick.title, "Quick")
        XCTAssertEqual(OnboardingTemplate.everyday.title, "Everyday")
        XCTAssertEqual(OnboardingTemplate.powerful.title, "Powerful")
        XCTAssertEqual(OnboardingTemplate.custom.title, "Custom")
    }

    func test_systemImageName_isThePinnedCardIconPerTier() {
        XCTAssertEqual(OnboardingTemplate.quick.systemImageName, "hare.fill")
        XCTAssertEqual(OnboardingTemplate.everyday.systemImageName, "sparkles")
        XCTAssertEqual(OnboardingTemplate.powerful.systemImageName, "bolt.fill")
        XCTAssertEqual(OnboardingTemplate.custom.systemImageName, "slider.horizontal.3")
    }

    func test_tagline_isUniqueAndNonEmptyPerTier() {
        let taglines = OnboardingTemplate.allCases.map(\.tagline)

        XCTAssertEqual(Set(taglines).count, taglines.count)
        for tagline in taglines {
            XCTAssertFalse(tagline.isEmpty)
        }
        XCTAssertEqual(OnboardingTemplate.quick.tagline, "Fast and lightweight")
        XCTAssertEqual(OnboardingTemplate.powerful.tagline, "Highest quality")
    }

    func test_detail_isUniquePerTierAndCustomExplainsBothUserPopulations() {
        let details = OnboardingTemplate.allCases.map(\.detail)

        XCTAssertEqual(Set(details).count, details.count)
        for detail in details {
            XCTAssertFalse(detail.isEmpty)
        }
        // Custom's copy must reassure returning users their tuned settings survive and point new
        // users at Settings for fine-tuning.
        XCTAssertTrue(OnboardingTemplate.custom.detail.contains("keep every setting"))
        XCTAssertTrue(OnboardingTemplate.custom.detail.contains("Settings"))
    }
}
