import XCTest
@testable import Cotabby

/// MLX settings persistence: the engine raw value, the MLX model ids per power source, and the
/// prompt-cache cap all survive a reload, and a value written by a newer build still loads.
@MainActor
final class SuggestionSettingsMLXTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        suiteNames.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let name = "cotabby.test.mlx-settings.\(UUID().uuidString)"
        suiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeModel(_ defaults: UserDefaults) -> SuggestionSettingsModel {
        let model = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        Self.retained.append(model)
        return model
    }

    func test_mlxSelectionAndModelSurviveReload() {
        let defaults = makeDefaults()
        let model = makeModel(defaults)
        XCTAssertEqual(model.mlxModelID, "")
        XCTAssertEqual(model.mlxPromptCacheBytes, 1 << 30)

        model.selectEngine(.mlx)
        model.setMLXModelID("mlx-community/gemma-4-e4b-5bit")
        model.setMLXPromptCacheBytes(2 << 30)

        let reloaded = makeModel(defaults)
        XCTAssertEqual(reloaded.selectedEngine, .mlx)
        XCTAssertEqual(reloaded.mlxModelID, "mlx-community/gemma-4-e4b-5bit")
        XCTAssertEqual(reloaded.mlxPromptCacheBytes, 2 << 30)
    }

    func test_promptCacheCapIsClamped() {
        let model = makeModel(makeDefaults())
        model.setMLXPromptCacheBytes(1)
        XCTAssertEqual(model.mlxPromptCacheBytes, 256 << 20)
        model.setMLXPromptCacheBytes(64 << 30)
        XCTAssertEqual(model.mlxPromptCacheBytes, 8 << 30)
    }

    func test_unknownEngineRawValueFallsBackToOpenSource() {
        let defaults = makeDefaults()
        defaults.set("someFutureEngine", forKey: "cotabbySelectedEngine")
        XCTAssertEqual(makeModel(defaults).selectedEngine, .llamaOpenSource)
    }

    func test_mlxPowerProfilesRoundTrip() {
        let defaults = makeDefaults()
        let model = makeModel(defaults)
        model.setBatteryProfile(.mlx(modelID: "mlx-community/gemma-4-e2b-6bit"))
        model.setPluggedInProfile(.llama(filename: "a.gguf"))

        let reloaded = makeModel(defaults)
        XCTAssertEqual(reloaded.batteryProfile, .mlx(modelID: "mlx-community/gemma-4-e2b-6bit"))
        XCTAssertEqual(reloaded.pluggedInProfile, .llama(filename: "a.gguf"))
    }

    func test_initializePowerProfilesSeedsFromTheActiveMLXModel() {
        let model = makeModel(makeDefaults())
        model.initializePowerProfiles(
            currentEngine: .mlx,
            currentModelFilename: nil,
            currentMLXModelID: "mlx-community/gemma-4-e4b-5bit"
        )
        XCTAssertEqual(model.batteryProfile, .mlx(modelID: "mlx-community/gemma-4-e4b-5bit"))
        XCTAssertEqual(model.pluggedInProfile, .mlx(modelID: "mlx-community/gemma-4-e4b-5bit"))
    }
}
