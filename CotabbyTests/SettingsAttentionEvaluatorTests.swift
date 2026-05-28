import XCTest
@testable import Cotabby

/// Tests for the pure attention-decision rule that drives sidebar dots and per-pane callouts in
/// the redesigned Settings window. Each test pins one real-world condition so a future change to
/// the rule has to update an obvious assertion rather than slip through.
final class SettingsAttentionEvaluatorTests: XCTestCase {
    private func makeInputs(
        permissionsGranted: Bool = true,
        selectedEngine: SuggestionEngineKind = .llamaOpenSource,
        foundationModelAvailable: Bool = true,
        foundationModelMessage: String = "Apple Intelligence is available.",
        llamaRuntimeFailedReason: String? = nil
    ) -> SettingsAttentionEvaluator.Inputs {
        SettingsAttentionEvaluator.Inputs(
            permissionsGranted: permissionsGranted,
            selectedEngine: selectedEngine,
            foundationModelAvailable: foundationModelAvailable,
            foundationModelMessage: foundationModelMessage,
            llamaRuntimeFailedReason: llamaRuntimeFailedReason
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

    /// Apple Intelligence unavailability flags both the sub-row and its parent so the user sees
    /// the dot regardless of which row their eye lands on first.
    func test_appleIntelligenceUnavailable_flagsSubRowAndParent() {
        let categories = SettingsAttentionEvaluator.categoriesNeedingAttention(
            makeInputs(
                selectedEngine: .appleIntelligence,
                foundationModelAvailable: false,
                foundationModelMessage: "Apple Intelligence is turned off in System Settings."
            )
        )
        XCTAssertEqual(categories, [.appleIntelligence, .engineAndModel])
    }

    /// The flag is engine-scoped: if the user is on Open Source, FM availability doesn't matter.
    func test_appleIntelligenceUnavailable_butLlamaSelected_noAppleAttention() {
        let categories = SettingsAttentionEvaluator.categoriesNeedingAttention(
            makeInputs(
                selectedEngine: .llamaOpenSource,
                foundationModelAvailable: false
            )
        )
        XCTAssertFalse(categories.contains(.appleIntelligence))
        XCTAssertFalse(categories.contains(.engineAndModel))
    }

    func test_llamaRuntimeFailed_flagsOpenSourceAndParent() {
        let categories = SettingsAttentionEvaluator.categoriesNeedingAttention(
            makeInputs(
                selectedEngine: .llamaOpenSource,
                llamaRuntimeFailedReason: "Model failed to load."
            )
        )
        XCTAssertEqual(categories, [.openSource, .engineAndModel])
    }

    func test_callout_permissions_returnsActionableMessage() {
        let message = SettingsAttentionEvaluator.calloutMessage(
            for: .permissions,
            inputs: makeInputs(permissionsGranted: false)
        )
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("more access") ?? false)
    }

    func test_callout_appleIntelligence_echoesAvailabilityMessage() {
        let inputs = makeInputs(
            selectedEngine: .appleIntelligence,
            foundationModelAvailable: false,
            foundationModelMessage: "This Mac is not eligible for Apple Intelligence."
        )
        let message = SettingsAttentionEvaluator.calloutMessage(for: .appleIntelligence, inputs: inputs)
        XCTAssertEqual(message, "This Mac is not eligible for Apple Intelligence.")
    }

    func test_callout_openSource_echoesRuntimeFailureReason() {
        let inputs = makeInputs(
            selectedEngine: .llamaOpenSource,
            llamaRuntimeFailedReason: "Couldn't open the GGUF file."
        )
        let message = SettingsAttentionEvaluator.calloutMessage(for: .openSource, inputs: inputs)
        XCTAssertEqual(message, "Couldn't open the GGUF file.")
    }

    func test_callout_paneWithoutAttention_isNil() {
        let inputs = makeInputs()
        for category in [SettingsCategory.general, .writing, .shortcuts, .apps, .about] {
            XCTAssertNil(
                SettingsAttentionEvaluator.calloutMessage(for: category, inputs: inputs),
                "\(category) should never carry a callout"
            )
        }
    }

    func test_callout_engineAndModel_neverReturnsItsOwnMessage() {
        // The parent pane gets a sidebar dot but the actionable message lives on the sub-pane.
        let inputs = makeInputs(
            selectedEngine: .appleIntelligence,
            foundationModelAvailable: false,
            foundationModelMessage: "Apple Intelligence is turned off."
        )
        XCTAssertNil(
            SettingsAttentionEvaluator.calloutMessage(for: .engineAndModel, inputs: inputs)
        )
    }
}
