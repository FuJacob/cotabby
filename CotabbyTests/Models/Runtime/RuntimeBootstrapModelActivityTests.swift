import Foundation
import XCTest
@testable import Cotabby

/// Pins that `RuntimeBootstrapModel` drives one runtime operation at a time. Loads go through a
/// gated loader so a start can be held in flight while a second request arrives.
@MainActor
final class RuntimeBootstrapModelActivityTests: XCTestCase {
    private static let selectionKey = "cotabbySelectedModelFilename"

    private func makeModel(_ loader: GatedModelLoader) throws -> (model: RuntimeBootstrapModel, userDefaults: UserDefaults) {
        let manager = try loader.makeManager(in: makeTemporaryDirectory(), filenames: ["alpha.gguf", "beta.gguf"])
        let userDefaults = IsolatedUserDefaults.make()
        let model = TestLifetime.retain(RuntimeBootstrapModel(runtimeManager: manager, userDefaults: userDefaults))
        return (model, userDefaults)
    }

    func test_startIfNeeded_loadsTheSelectedModel() async throws {
        let loader = GatedModelLoader()
        loader.holdLoads()
        let (model, _) = try makeModel(loader)

        model.startIfNeeded()
        model.startIfNeeded()
        try await loader.waitForStartedLoads(1)
        XCTAssertEqual(model.state, .loading("Loading alpha.gguf into memory."))

        loader.release(call: 0)
        try await waitForState(of: model, .ready("Loaded alpha.gguf in-process."))
        XCTAssertEqual(loader.startedFilenames, ["alpha.gguf"])
    }

    /// A selection made while the runtime is still starting is refused, not queued: the picker
    /// keeps the previous model and nothing is persisted or reloaded.
    func test_selectModel_duringStartupIsIgnored() async throws {
        let loader = GatedModelLoader()
        loader.holdLoads()
        let (model, userDefaults) = try makeModel(loader)
        var reloads = 0
        model.onWillReloadModel = { reloads += 1 }

        model.startIfNeeded()
        try await loader.waitForStartedLoads(1)
        await model.selectModel("beta.gguf")

        XCTAssertEqual(model.selectedModelFilename, "alpha.gguf")
        XCTAssertEqual(userDefaults.string(forKey: Self.selectionKey), "alpha.gguf")
        XCTAssertEqual(reloads, 0)

        loader.release(call: 0)
        try await waitForState(of: model, .ready("Loaded alpha.gguf in-process."))
        XCTAssertEqual(loader.startedFilenames, ["alpha.gguf"])
    }

    func test_selectModel_afterStartupSwitchesModels() async throws {
        let loader = GatedModelLoader()
        let (model, userDefaults) = try makeModel(loader)
        model.startIfNeeded()
        try await waitForState(of: model, .ready("Loaded alpha.gguf in-process."))
        // The ready state is published just before the start operation itself returns.
        for _ in 0..<20 {
            await Task.yield()
        }

        await model.selectModel("beta.gguf")

        XCTAssertEqual(model.selectedModelFilename, "beta.gguf")
        XCTAssertEqual(userDefaults.string(forKey: Self.selectionKey), "beta.gguf")
        XCTAssertEqual(model.state, .ready("Loaded beta.gguf in-process."))
        XCTAssertEqual(loader.startedFilenames, ["alpha.gguf", "beta.gguf"])
    }

    /// A start cancelled by `stop()` finishes later than the stop. When it does, it must not mark
    /// the model idle while the start that followed the stop is still in flight.
    func test_startAfterStop_staysBusyWhenTheStoppedStartFinishes() async throws {
        let loader = GatedModelLoader()
        loader.holdLoads()
        let (model, _) = try makeModel(loader)

        model.startIfNeeded()
        try await loader.waitForStartedLoads(1)
        model.stop()
        XCTAssertEqual(model.state, .idle)
        model.startIfNeeded()
        try await loader.waitForStartedLoads(2)

        loader.release(call: 0)
        // Give the stopped start time to unwind; there is no state change to await because the
        // point of the test is that it publishes nothing.
        try await Task.sleep(for: .milliseconds(150))
        await model.selectModel("beta.gguf")
        XCTAssertEqual(model.selectedModelFilename, "alpha.gguf", "The second start is still in flight")

        loader.release(call: 1)
        try await waitForState(of: model, .ready("Loaded alpha.gguf in-process."))
    }

    private func waitForState(
        of model: RuntimeBootstrapModel,
        _ expected: RuntimeBootstrapState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1_000 {
            if model.state == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Expected \(expected), got \(model.state)", file: file, line: line)
    }
}
