import XCTest
@testable import Cotabby

/// Tests for the pure rules that turn an onboarding template into a concrete plan and decide which
/// templates to recommend, warn about, or disable on a given Mac. The engine is now an explicit
/// input (chosen at the top of the onboarding step), so every tier follows the selected engine:
/// Apple Intelligence downloads nothing, Open Source maps each tier to its local GGUF. Each case
/// pins one product decision so a future tweak has to update an obvious assertion.
final class OnboardingTemplateRecommenderTests: XCTestCase {
    private func hardware(gigabytes: Double, appleSilicon: Bool = true) -> HardwareCapability {
        HardwareCapability(
            physicalMemoryBytes: UInt64(gigabytes * 1_073_741_824),
            isAppleSilicon: appleSilicon
        )
    }

    // MARK: - resolvePlan: Apple Intelligence engine (no downloads, tier tunes behavior)

    func testAppleIntelligenceTiersDownloadNothing() {
        for template in OnboardingTemplate.allCases {
            let plan = OnboardingTemplateRecommender.resolvePlan(for: template, engine: .appleIntelligence)
            XCTAssertEqual(plan.engine, .appleIntelligence)
            XCTAssertNil(plan.modelToDownload, "\(template) on Apple Intelligence must download nothing.")
        }
    }

    func testAppleIntelligenceStillCarriesTierBehaviorFlags() {
        let quick = OnboardingTemplateRecommender.resolvePlan(for: .quick, engine: .appleIntelligence)
        XCTAssertEqual(quick.wordCountPreset, .threeToSeven)
        XCTAssertTrue(quick.enablesFastMode)
        XCTAssertFalse(quick.enablesMultiLine)
        XCTAssertFalse(quick.enablesClipboardContext)

        let everyday = OnboardingTemplateRecommender.resolvePlan(for: .everyday, engine: .appleIntelligence)
        XCTAssertFalse(everyday.enablesFastMode)
        XCTAssertFalse(everyday.enablesMultiLine)
        XCTAssertTrue(everyday.enablesClipboardContext)

        let powerful = OnboardingTemplateRecommender.resolvePlan(for: .powerful, engine: .appleIntelligence)
        XCTAssertEqual(powerful.wordCountPreset, .twelveToTwenty)
        XCTAssertFalse(powerful.enablesMultiLine)
        XCTAssertTrue(powerful.enablesClipboardContext)
    }

    // MARK: - resolvePlan: Open Source engine (each tier maps to its GGUF)

    func testOpenSourceTiersMapToTheirLocalModels() {
        let expected: [OnboardingTemplate: String] = [
            .quick: "SmolLM2-135M-Instruct-q8_0.gguf",
            .everyday: "gemma-4-E2B-it-Q4_K_M.gguf",
            .powerful: "gemma-4-E4B-it-Q4_K_M.gguf"
        ]
        for (template, filename) in expected {
            let plan = OnboardingTemplateRecommender.resolvePlan(for: template, engine: .llamaOpenSource)
            XCTAssertEqual(plan.engine, .llamaOpenSource)
            XCTAssertEqual(plan.modelToDownload?.filename, filename)
        }
    }

    // MARK: - availability gating (Open Source engine)

    func testPowerfulDisabledOnLowMemoryMacOpenSource() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .powerful,
            hardware: hardware(gigabytes: 8),
            engine: .llamaOpenSource
        )

        XCTAssertTrue(availability.isDisabled)
        XCTAssertNotNil(availability.warning)
    }

    func testPowerfulWarnsBetweenDisableFloorAndComfortCeiling() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .powerful,
            hardware: hardware(gigabytes: 12),
            engine: .llamaOpenSource
        )

        XCTAssertFalse(availability.isDisabled)
        XCTAssertNotNil(availability.warning)
    }

    func testPowerfulCleanOnHighMemoryMac() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .powerful,
            hardware: hardware(gigabytes: 32),
            engine: .llamaOpenSource
        )

        XCTAssertFalse(availability.isDisabled)
        XCTAssertNil(availability.warning)
    }

    func testEverydayWarnsOnLowMemoryUnderOpenSource() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .everyday,
            hardware: hardware(gigabytes: 6),
            engine: .llamaOpenSource
        )

        XCTAssertFalse(availability.isDisabled)
        XCTAssertNotNil(availability.warning)
    }

    // MARK: - availability gating (Apple Intelligence engine: never blocked)

    func testAppleIntelligenceNeverDisablesOrWarnsEvenOnLowMemory() {
        for template in OnboardingTemplate.allCases {
            let availability = OnboardingTemplateRecommender.availability(
                for: template,
                hardware: hardware(gigabytes: 6),
                engine: .appleIntelligence
            )
            XCTAssertFalse(availability.isDisabled, "\(template) must be available on Apple Intelligence.")
            XCTAssertNil(availability.warning, "\(template) must not warn on Apple Intelligence.")
        }
    }

    func testQuickIsNeverDisabledOrWarned() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .quick,
            hardware: hardware(gigabytes: 4),
            engine: .llamaOpenSource
        )

        XCTAssertFalse(availability.isDisabled)
        XCTAssertNil(availability.warning)
    }

    // MARK: - recommendation

    func testRecommendsEverydayOnAppleIntelligence() {
        let recommended = OnboardingTemplateRecommender.recommendedTemplate(
            hardware: hardware(gigabytes: 8),
            engine: .appleIntelligence
        )

        XCTAssertEqual(recommended, .everyday)
    }

    func testRecommendsQuickOnLowMemoryOpenSource() {
        let recommended = OnboardingTemplateRecommender.recommendedTemplate(
            hardware: hardware(gigabytes: 6),
            engine: .llamaOpenSource
        )

        XCTAssertEqual(recommended, .quick)
    }

    func testRecommendsEverydayOnCapableMemoryOpenSource() {
        let recommended = OnboardingTemplateRecommender.recommendedTemplate(
            hardware: hardware(gigabytes: 16),
            engine: .llamaOpenSource
        )

        XCTAssertEqual(recommended, .everyday)
    }

    func testRecommendedFlagMatchesRecommendedTemplate() {
        let host = hardware(gigabytes: 16)
        let availability = OnboardingTemplateRecommender.availability(
            for: .everyday,
            hardware: host,
            engine: .llamaOpenSource
        )

        XCTAssertTrue(availability.isRecommended)

        let quickAvailability = OnboardingTemplateRecommender.availability(
            for: .quick,
            hardware: host,
            engine: .llamaOpenSource
        )
        XCTAssertFalse(quickAvailability.isRecommended)
    }
}
