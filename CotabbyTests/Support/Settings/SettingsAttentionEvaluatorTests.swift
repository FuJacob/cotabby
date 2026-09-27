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
        XCTAssertEqual(SettingsAttentionEvaluator.categoriesNeedingAttention(makeInputs()), [])
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

    /// Engine attention is scoped to the selected engine: another engine's failure signal is
    /// irrelevant to the backend the user is actually running.
    func test_otherEnginesFailureSignals_doNotFlagSelectedEngine() {
        let cases: [(engine: SuggestionEngineKind, inputs: SettingsAttentionEvaluator.Inputs)] = [
            (.llamaOpenSource, makeInputs(
                selectedEngine: .llamaOpenSource, foundationModelAvailable: false,
                endpointConfigurationError: "Choose a model.", endpointConnectionFailedReason: "Refused."
            )),
            (.appleIntelligence, makeInputs(
                selectedEngine: .appleIntelligence, llamaRuntimeFailedReason: "Model failed to load.",
                endpointConfigurationError: "Choose a model."
            )),
            (.openAICompatible, makeInputs(
                selectedEngine: .openAICompatible, foundationModelAvailable: false,
                llamaRuntimeFailedReason: "Model failed to load."
            ))
        ]
        for testCase in cases {
            XCTAssertEqual(
                SettingsAttentionEvaluator.categoriesNeedingAttention(testCase.inputs),
                [],
                "\(testCase.engine)"
            )
        }
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

    func test_endpointConnectionFailure_flagsEngineAndModel() {
        let inputs = makeInputs(
            selectedEngine: .openAICompatible,
            endpointConnectionFailedReason: "Connection refused."
        )
        XCTAssertEqual(SettingsAttentionEvaluator.categoriesNeedingAttention(inputs), [.engineAndModel])
    }

    /// Independent problems accumulate rather than one masking the other.
    func test_missingPermissionsAndEngineFailure_flagBothPanes() {
        let inputs = makeInputs(
            permissionsGranted: false,
            selectedEngine: .llamaOpenSource,
            llamaRuntimeFailedReason: "Model failed to load."
        )
        XCTAssertEqual(SettingsAttentionEvaluator.categoriesNeedingAttention(inputs), [.permissions, .engineAndModel])
    }
}
