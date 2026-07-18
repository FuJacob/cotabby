import XCTest
@testable import Cotabby

/// Tests for the pure attention-decision rule that drives sidebar dots in the redesigned Settings
/// window. Each test pins one real-world condition so a future change to
/// the rule has to update an obvious assertion rather than slip through.
final class SettingsAttentionEvaluatorTests: XCTestCase {
    private func makeInputs(
        permissionsGranted: Bool = true,
        selectedEngine: SuggestionEngineKind = .llamaOpenSource,
        foundationModelAvailable: Bool = true,
        llamaRuntimeFailedReason: String? = nil,
        endpointConfigurationError: String? = nil,
        endpointConnectionFailedReason: String? = nil
    ) -> SettingsAttentionEvaluator.Inputs {
        SettingsAttentionEvaluator.Inputs(
            permissionsGranted: permissionsGranted,
            selectedEngine: selectedEngine,
            foundationModelAvailable: foundationModelAvailable,
            llamaRuntimeFailedReason: llamaRuntimeFailedReason,
            endpointConfigurationError: endpointConfigurationError,
            endpointConnectionFailedReason: endpointConnectionFailedReason
        )
    }

    func test_allHealthy_noAttention() {
        let categories = SettingsAttentionEvaluator.categoriesNeedingAttention(makeInputs())
        XCTAssertTrue(categories.isEmpty)
    }

    func test_missingPermissions_flagsPermissionsPane() {
        let categories = SettingsAttentionEvaluator.categoriesNeedingAttention(
            makeInputs(permissionsGranted: false)
        )
        XCTAssertEqual(categories, [.permissions])
    }

    /// Apple Intelligence unavailability flags the unified Engine & Model row — the dedicated
    /// sub-row was removed when the sidebar was flattened.
    func test_appleIntelligenceUnavailable_flagsEngineAndModel() {
        let categories = SettingsAttentionEvaluator.categoriesNeedingAttention(
            makeInputs(
                selectedEngine: .appleIntelligence,
                foundationModelAvailable: false
            )
        )
        XCTAssertEqual(categories, [.engineAndModel])
    }

    /// The flag is engine-scoped: if the user is on Open Source, FM availability doesn't matter.
    func test_appleIntelligenceUnavailable_butLlamaSelected_noEngineAttention() {
        let categories = SettingsAttentionEvaluator.categoriesNeedingAttention(
            makeInputs(
                selectedEngine: .llamaOpenSource,
                foundationModelAvailable: false
            )
        )
        XCTAssertFalse(categories.contains(.engineAndModel))
    }

    func test_llamaRuntimeFailed_flagsEngineAndModel() {
        let categories = SettingsAttentionEvaluator.categoriesNeedingAttention(
            makeInputs(
                selectedEngine: .llamaOpenSource,
                llamaRuntimeFailedReason: "Model failed to load."
            )
        )
        XCTAssertEqual(categories, [.engineAndModel])
    }

    func test_endpointConfigurationFailure_flagsEngineAndModel() {
        let inputs = makeInputs(
            selectedEngine: .openAICompatible,
            endpointConfigurationError: "Choose a model."
        )
        XCTAssertEqual(SettingsAttentionEvaluator.categoriesNeedingAttention(inputs), [.engineAndModel])
    }
}
