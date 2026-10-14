import XCTest
@testable import Cotabby

/// Pins the engine-picker gating shared by Settings and the menu bar so Apple Intelligence can never
/// again be offered as a selectable engine on a Mac that cannot run it, while the other engines stay
/// selectable regardless of Apple Intelligence availability.
final class SuggestionEngineSelectionPolicyTests: XCTestCase {
    func test_isSelectable_appleIntelligenceFollowsAvailability() {
        XCTAssertTrue(
            SuggestionEngineSelectionPolicy.isSelectable(.appleIntelligence, foundationModelAvailable: true)
        )
        XCTAssertFalse(
            SuggestionEngineSelectionPolicy.isSelectable(.appleIntelligence, foundationModelAvailable: false)
        )
    }

    func test_isSelectable_otherEnginesIgnoreAppleAvailability() {
        for engine in [SuggestionEngineKind.llamaOpenSource, .openAICompatible, .mlx] {
            for available in [true, false] {
                XCTAssertTrue(
                    SuggestionEngineSelectionPolicy.isSelectable(
                        engine, foundationModelAvailable: available, isAppleSilicon: true
                    ),
                    "\(engine) available=\(available)"
                )
            }
        }
    }

    func test_mlxNeedsAppleSilicon() {
        XCTAssertTrue(SuggestionEngineSelectionPolicy.isSelectable(
            .mlx, foundationModelAvailable: false, isAppleSilicon: true))
        XCTAssertFalse(SuggestionEngineSelectionPolicy.isSelectable(
            .mlx, foundationModelAvailable: true, isAppleSilicon: false))
        XCTAssertEqual(
            SuggestionEngineSelectionPolicy.pickerLabel(
                for: .mlx, foundationModelAvailable: true, isAppleSilicon: false),
            "MLX (Unavailable)"
        )
        // Intel does not affect the engines that do not need MLX.
        XCTAssertTrue(SuggestionEngineSelectionPolicy.isSelectable(
            .llamaOpenSource, foundationModelAvailable: false, isAppleSilicon: false))
    }

    func test_pickerLabel_marksOnlyUnselectableEngines() {
        XCTAssertEqual(
            SuggestionEngineSelectionPolicy.pickerLabel(for: .appleIntelligence, foundationModelAvailable: false),
            "Apple Intelligence (Unavailable)"
        )
        for engine in SuggestionEngineKind.allCases {
            XCTAssertEqual(
                SuggestionEngineSelectionPolicy.pickerLabel(for: engine, foundationModelAvailable: true),
                engine.displayLabel
            )
        }
        XCTAssertEqual(
            SuggestionEngineSelectionPolicy.pickerLabel(for: .llamaOpenSource, foundationModelAvailable: false),
            SuggestionEngineKind.llamaOpenSource.displayLabel
        )
    }
}
