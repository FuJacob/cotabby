import XCTest
@testable import Cotabby

/// Pins the two per-engine questions every privacy and speculation gate asks, so adding an engine
/// forces an explicit answer instead of inheriting one from a `!= .openAICompatible` comparison.
final class SuggestionEngineKindTests: XCTestCase {
    func test_mlxIsLabelledAndIconned() {
        XCTAssertEqual(SuggestionEngineKind.mlx.displayLabel, "MLX")
        XCTAssertEqual(SuggestionEngineKind.mlx.systemImageName, "bolt.fill")
        XCTAssertFalse(SuggestionEngineKind.mlx.supportsLocalModelManagement)
        XCTAssertEqual(SuggestionEngineKind(rawValue: "mlx"), .mlx)
    }

    func test_onlyTheEndpointLeavesTheMac() {
        XCTAssertTrue(SuggestionEngineKind.appleIntelligence.isOnDevice)
        XCTAssertTrue(SuggestionEngineKind.llamaOpenSource.isOnDevice)
        XCTAssertTrue(SuggestionEngineKind.mlx.isOnDevice)
        XCTAssertFalse(SuggestionEngineKind.openAICompatible.isOnDevice)
    }

    func test_onlyInProcessEnginesRunSpeculativeWork() {
        XCTAssertTrue(SuggestionEngineKind.appleIntelligence.allowsSpeculativeGeneration)
        XCTAssertTrue(SuggestionEngineKind.llamaOpenSource.allowsSpeculativeGeneration)
        XCTAssertFalse(SuggestionEngineKind.mlx.allowsSpeculativeGeneration)
        XCTAssertFalse(SuggestionEngineKind.openAICompatible.allowsSpeculativeGeneration)
    }

    func test_mlxPowerProfileSelectsTheMLXEngine() {
        XCTAssertEqual(PowerProfile.mlx(modelID: "org/m").engine, .mlx)
    }
}
