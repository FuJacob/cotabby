import XCTest
@testable import Cotabby

/// Tests for the two decisions the onboarding wizard makes about a chosen template: which plan it
/// actually applies for a returning user, and whether Continue is enabled on the template step.
@MainActor
final class OnboardingTemplateWizardRulesTests: XCTestCase {
    /// A catalog model that is not the Custom template's default, standing in for "the model this
    /// returning user already picked".
    private func nonDefaultCatalogModel() throws -> DownloadableRuntimeModel {
        try XCTUnwrap(RuntimeModelCatalog.downloadableModels.first {
            $0.filename != OnboardingTemplate.custom.openSourceModelFilename
        })
    }

    private func plan(
        _ template: OnboardingTemplate,
        engine: SuggestionEngineKind = .llamaOpenSource,
        isReturningUser: Bool,
        currentModelFilename: String?
    ) -> ResolvedTemplatePlan {
        OnboardingTemplateRecommender.resolvePlan(
            for: template,
            engine: engine,
            isReturningUser: isReturningUser,
            currentModelFilename: currentModelFilename
        )
    }

    // MARK: - Plan for a returning user

    func test_returningUserOnCustomOpenSource_keepsTheirCurrentModel() throws {
        let current = try nonDefaultCatalogModel()
        let base = OnboardingTemplateRecommender.resolvePlan(for: .custom, engine: .llamaOpenSource)

        let resolved = plan(.custom, isReturningUser: true, currentModelFilename: current.filename)

        XCTAssertEqual(resolved.modelToDownload, current)
        // Only the model is swapped; the template's behavior flags are untouched.
        XCTAssertEqual(resolved.engine, base.engine)
        XCTAssertEqual(resolved.wordCountPreset, base.wordCountPreset)
        XCTAssertEqual(resolved.enablesFastMode, base.enablesFastMode)
        XCTAssertEqual(resolved.enablesMultiLine, base.enablesMultiLine)
        XCTAssertEqual(resolved.enablesClipboardContext, base.enablesClipboardContext)
    }

    func test_currentModelOutsideTheCatalog_fallsBackToTheTemplatePlan() {
        let base = OnboardingTemplateRecommender.resolvePlan(for: .custom, engine: .llamaOpenSource)

        XCTAssertEqual(plan(.custom, isReturningUser: true, currentModelFilename: "my-own-model.gguf"), base)
        XCTAssertEqual(plan(.custom, isReturningUser: true, currentModelFilename: nil), base)
    }

    func test_theOverrideAppliesOnlyToReturningUsersOnCustomWithOpenSource() throws {
        let current = try nonDefaultCatalogModel().filename

        // A new user gets the template default even if a model happens to be selected.
        XCTAssertEqual(
            plan(.custom, isReturningUser: false, currentModelFilename: current),
            OnboardingTemplateRecommender.resolvePlan(for: .custom, engine: .llamaOpenSource)
        )
        // Picking a curated tier is an explicit choice of that tier's model.
        for template in OnboardingTemplate.allCases where template != .custom {
            XCTAssertEqual(
                plan(template, isReturningUser: true, currentModelFilename: current),
                OnboardingTemplateRecommender.resolvePlan(for: template, engine: .llamaOpenSource),
                "\(template)"
            )
        }
        // Apple Intelligence downloads nothing, whatever local model is selected.
        XCTAssertNil(
            plan(.custom, engine: .appleIntelligence, isReturningUser: true, currentModelFilename: current)
                .modelToDownload
        )
    }

    // MARK: - Continue gate on the template step

    private func canContinue(
        engine: SuggestionEngineKind?,
        downloadState: ModelDownloadState?
    ) -> Bool {
        OnboardingTemplateRecommender.canContinueFromTemplateStep(
            selectedPlan: engine.map { OnboardingTemplateRecommender.resolvePlan(for: .everyday, engine: $0) },
            modelDownloadState: downloadState
        )
    }

    func test_noTierChosen_neverBlocksBecauseTheButtonIsSetUpLater() {
        XCTAssertTrue(canContinue(engine: nil, downloadState: nil))
        XCTAssertTrue(canContinue(engine: nil, downloadState: .idle))
    }

    func test_appleIntelligenceAndEndpointTiers_neverBlock() {
        for engine in [SuggestionEngineKind.appleIntelligence, .openAICompatible] {
            XCTAssertTrue(canContinue(engine: engine, downloadState: nil), "\(engine)")
            XCTAssertTrue(canContinue(engine: engine, downloadState: .idle), "\(engine)")
        }
    }

    func test_openSourceTier_blocksUntilTheDownloadIsUnderwayOrDone() {
        XCTAssertFalse(canContinue(engine: .llamaOpenSource, downloadState: nil))
        XCTAssertFalse(canContinue(engine: .llamaOpenSource, downloadState: .idle))
        XCTAssertFalse(canContinue(engine: .llamaOpenSource, downloadState: .paused(progress: 0.4)))
        XCTAssertFalse(canContinue(engine: .llamaOpenSource, downloadState: .failed("offline")))

        XCTAssertTrue(canContinue(engine: .llamaOpenSource, downloadState: .downloading(progress: nil)))
        XCTAssertTrue(canContinue(engine: .llamaOpenSource, downloadState: .downloading(progress: 0.1)))
        XCTAssertTrue(canContinue(engine: .llamaOpenSource, downloadState: .downloaded))
    }
}
