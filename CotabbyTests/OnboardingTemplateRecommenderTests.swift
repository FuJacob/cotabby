import XCTest
@testable import Cotabby

/// Tests for the pure rules that turn an onboarding template into a concrete plan and decide which
/// templates to recommend, warn about, or disable on a given Mac. Each case pins one product
/// decision so a future tweak to the thresholds has to update an obvious assertion.
final class OnboardingTemplateRecommenderTests: XCTestCase {
    private func hardware(gigabytes: Double, appleSilicon: Bool = true) -> HardwareCapability {
        HardwareCapability(
            physicalMemoryBytes: UInt64(gigabytes * 1_073_741_824),
            isAppleSilicon: appleSilicon
        )
    }

    // MARK: - resolvePlan

    func testQuickAlwaysResolvesToLocalMiniModel() {
        let plan = OnboardingTemplateRecommender.resolvePlan(for: .quick, appleIntelligenceAvailable: true)

        XCTAssertEqual(plan.engine, .llamaOpenSource)
        XCTAssertEqual(plan.modelToDownload?.filename, "Qwen3-0.6B-Q4_K_M.gguf")
        XCTAssertEqual(plan.wordCountPreset, .threeToSeven)
        XCTAssertTrue(plan.enablesFastMode)
        XCTAssertFalse(plan.enablesMultiLine)
    }

    func testEverydayUsesAppleIntelligenceWhenAvailable() {
        let plan = OnboardingTemplateRecommender.resolvePlan(for: .everyday, appleIntelligenceAvailable: true)

        XCTAssertEqual(plan.engine, .appleIntelligence)
        XCTAssertNil(plan.modelToDownload, "Apple Intelligence plans download nothing.")
        XCTAssertEqual(plan.wordCountPreset, .sevenToTwelve)
    }

    func testEverydayFallsBackToLocalBaseModelWithoutAppleIntelligence() {
        let plan = OnboardingTemplateRecommender.resolvePlan(for: .everyday, appleIntelligenceAvailable: false)

        XCTAssertEqual(plan.engine, .llamaOpenSource)
        XCTAssertEqual(plan.modelToDownload?.filename, "gemma-4-E2B-it-Q4_K_M.gguf")
    }

    func testPowerfulAlwaysResolvesToLocalProModel() {
        let plan = OnboardingTemplateRecommender.resolvePlan(for: .powerful, appleIntelligenceAvailable: true)

        XCTAssertEqual(plan.engine, .llamaOpenSource)
        XCTAssertEqual(plan.modelToDownload?.filename, "gemma-4-E4B-it-Q4_K_M.gguf")
        XCTAssertEqual(plan.wordCountPreset, .twelveToTwenty)
        XCTAssertTrue(plan.enablesMultiLine)
    }

    // MARK: - availability gating

    func testPowerfulDisabledOnLowMemoryMac() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .powerful,
            hardware: hardware(gigabytes: 8),
            appleIntelligenceAvailable: false
        )

        XCTAssertTrue(availability.isDisabled)
        XCTAssertNotNil(availability.warning)
    }

    func testPowerfulWarnsBetweenDisableFloorAndComfortCeiling() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .powerful,
            hardware: hardware(gigabytes: 12),
            appleIntelligenceAvailable: false
        )

        XCTAssertFalse(availability.isDisabled)
        XCTAssertNotNil(availability.warning)
    }

    func testPowerfulCleanOnHighMemoryMac() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .powerful,
            hardware: hardware(gigabytes: 32),
            appleIntelligenceAvailable: false
        )

        XCTAssertFalse(availability.isDisabled)
        XCTAssertNil(availability.warning)
    }

    func testEverydayWarnsOnLowMemoryWithoutAppleIntelligence() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .everyday,
            hardware: hardware(gigabytes: 6),
            appleIntelligenceAvailable: false
        )

        XCTAssertFalse(availability.isDisabled)
        XCTAssertNotNil(availability.warning)
    }

    func testEverydayNoWarningWhenAppleIntelligenceAvailableEvenOnLowMemory() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .everyday,
            hardware: hardware(gigabytes: 6),
            appleIntelligenceAvailable: true
        )

        XCTAssertNil(availability.warning)
    }

    func testQuickIsNeverDisabledOrWarned() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .quick,
            hardware: hardware(gigabytes: 4),
            appleIntelligenceAvailable: false
        )

        XCTAssertFalse(availability.isDisabled)
        XCTAssertNil(availability.warning)
    }

    // MARK: - recommendation

    func testRecommendsEverydayWhenAppleIntelligenceAvailable() {
        let recommended = OnboardingTemplateRecommender.recommendedTemplate(
            hardware: hardware(gigabytes: 8),
            appleIntelligenceAvailable: true
        )

        XCTAssertEqual(recommended, .everyday)
    }

    func testRecommendsQuickOnLowMemoryWithoutAppleIntelligence() {
        let recommended = OnboardingTemplateRecommender.recommendedTemplate(
            hardware: hardware(gigabytes: 6),
            appleIntelligenceAvailable: false
        )

        XCTAssertEqual(recommended, .quick)
    }

    func testRecommendsEverydayOnCapableMemoryWithoutAppleIntelligence() {
        let recommended = OnboardingTemplateRecommender.recommendedTemplate(
            hardware: hardware(gigabytes: 16),
            appleIntelligenceAvailable: false
        )

        XCTAssertEqual(recommended, .everyday)
    }

    func testRecommendedFlagMatchesRecommendedTemplate() {
        let host = hardware(gigabytes: 16)
        let availability = OnboardingTemplateRecommender.availability(
            for: .everyday,
            hardware: host,
            appleIntelligenceAvailable: false
        )

        XCTAssertTrue(availability.isRecommended)

        let quickAvailability = OnboardingTemplateRecommender.availability(
            for: .quick,
            hardware: host,
            appleIntelligenceAvailable: false
        )
        XCTAssertFalse(quickAvailability.isRecommended)
    }
}
