import XCTest
@testable import Cotabby

/// Tests for the pure rules that turn an onboarding template into a concrete plan and decide which
/// templates to recommend, warn about, or disable on a given Mac. The engine is now an explicit
/// input (chosen at the top of the onboarding step), so every tier follows the selected engine:
/// Apple Intelligence downloads nothing, Open Source maps each tier to its local GGUF. Each case
/// pins one product decision so a future tweak has to update an obvious assertion.
final class OnboardingTemplateRecommenderTests: XCTestCase {
    private func hardware(gigabytes: Double) -> HardwareCapability {
        HardwareCapability(
            physicalMemoryBytes: UInt64(gigabytes * 1_073_741_824)
        )
    }

    /// The catalog's size label for a template's GGUF, so the expected warning copy tracks the real
    /// model size instead of a number duplicated into the test.
    private func sizeLabel(_ template: OnboardingTemplate) -> String {
        let model = RuntimeModelCatalog.downloadableModels.first { $0.filename == template.openSourceModelFilename }
        return model?.approximateSizeLabel ?? "local"
    }

    private func openSourceAvailability(_ template: OnboardingTemplate, gigabytes: Double) -> OnboardingTemplateAvailability {
        OnboardingTemplateRecommender.availability(
            for: template,
            hardware: hardware(gigabytes: gigabytes),
            engine: .llamaOpenSource
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
        XCTAssertEqual(quick.wordCountPreset, .fourToSeven)
        XCTAssertFalse(quick.enablesFastMode)
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
            .quick: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf",
            .everyday: "gemma-4-E2B.i1-Q6_K.gguf",
            .powerful: "gemma-4-E4B.i1-Q4_K_M.gguf",
            .custom: "gemma-4-E2B.i1-Q6_K.gguf"
        ]
        for (template, filename) in expected {
            let plan = OnboardingTemplateRecommender.resolvePlan(for: template, engine: .llamaOpenSource)
            XCTAssertEqual(plan.engine, .llamaOpenSource)
            XCTAssertEqual(plan.modelToDownload?.filename, filename)
        }
    }

    // MARK: - availability gating (Open Source engine)

    func testPowerfulDisabledOnLowMemoryMacOpenSource() {
        // Sub-8 GB Macs (effectively pre-Apple-Silicon) cannot comfortably hold the model, so Powerful
        // is excluded there.
        let availability = openSourceAvailability(.powerful, gigabytes: 6)

        XCTAssertTrue(availability.isDisabled)
        XCTAssertEqual(
            availability.warning,
            "Needs more memory than this Mac has (uses a \(sizeLabel(.powerful)) model)."
        )
    }

    func testPowerfulWarnsBetweenDisableFloorAndComfortCeiling() {
        // 8 GB is the disable floor: allowed, not excluded, but still flagged below the 16 GB comfort
        // ceiling. This pins that a stock 8 GB Mac can run the Powerful base model (the smaller
        // base-model tiers no longer need the old 10 GB floor).
        let availability = openSourceAvailability(.powerful, gigabytes: 8)

        XCTAssertFalse(availability.isDisabled)
        XCTAssertEqual(
            availability.warning,
            "Uses a \(sizeLabel(.powerful)) model; may run slowly with less than 16 GB of memory."
        )
    }

    func testPowerfulCleanFromTheComfortCeilingUp() {
        for gigabytes in [16.0, 32.0] {
            let availability = openSourceAvailability(.powerful, gigabytes: gigabytes)
            XCTAssertFalse(availability.isDisabled, "\(gigabytes) GB")
            XCTAssertNil(availability.warning, "\(gigabytes) GB")
        }
    }

    func testEverydayAndCustomWarnOnlyBelowEightGigabytes() {
        for template in [OnboardingTemplate.everyday, .custom] {
            let low = openSourceAvailability(template, gigabytes: 6)
            XCTAssertFalse(low.isDisabled, "\(template)")
            XCTAssertEqual(
                low.warning,
                "Uses a \(sizeLabel(template)) model, which may run slowly on this Mac.",
                "\(template)"
            )
            XCTAssertNil(openSourceAvailability(template, gigabytes: 8).warning, "\(template) at 8 GB")
        }
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
        let availability = openSourceAvailability(.quick, gigabytes: 4)

        XCTAssertFalse(availability.isDisabled)
        XCTAssertNil(availability.warning)
        // On a low-memory Mac Quick is also the recommended tier.
        XCTAssertTrue(availability.isRecommended)
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

    func testRecommendsEverydayFromEightGigabytesOpenSource() {
        // 8 GB is inclusive: the Quick fallback applies strictly below it.
        for gigabytes in [8.0, 16.0] {
            let recommended = OnboardingTemplateRecommender.recommendedTemplate(
                hardware: hardware(gigabytes: gigabytes),
                engine: .llamaOpenSource
            )
            XCTAssertEqual(recommended, .everyday, "\(gigabytes) GB")
        }
    }

    func testAppleIntelligenceRecommendsEverydayEvenOnLowMemory() {
        let availability = OnboardingTemplateRecommender.availability(
            for: .everyday,
            hardware: hardware(gigabytes: 4),
            engine: .appleIntelligence
        )
        XCTAssertTrue(availability.isRecommended)
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
