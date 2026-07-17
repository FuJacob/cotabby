import Combine
import Foundation
import XCTest
@testable import Cotabby

/// Exercises `RuntimeBootstrapModel`'s selection persistence, reconciliation, and lifecycle
/// forwarding against a real `LlamaRuntimeManager` pointed at a throwaway model directory.
///
/// No test ever lets a model load reach native llama.cpp: the planted `.gguf` files are deleted
/// before any prepare/select runs, so resolution fails inside `BundledRuntimeLocator` (pure file
/// checks) and the error paths complete deterministically in milliseconds.
///
/// Both `RuntimeBootstrapModel` and `LlamaRuntimeManager` are `@MainActor` with stored properties
/// and no `nonisolated deinit`, so instances are quarantined in a process-lifetime retain list
/// (the `InputMonitorTests` pattern) and all interactions run through `runOnMainActor`.
final class RuntimeBootstrapModelTests: XCTestCase {
    @MainActor private static var retainedModels: [RuntimeBootstrapModel] = []

    /// Persisted-selection key, mirrored from the production constant: it is a persistence
    /// contract across launches, so a silent rename should fail a test.
    private static let selectionKey = "cotabbySelectedModelFilename"

    private var temporaryDirectories: [URL] = []
    private var userDefaultsSuites: [(suiteName: String, userDefaults: UserDefaults)] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        for suite in userDefaultsSuites {
            suite.userDefaults.removePersistentDomain(forName: suite.suiteName)
        }
        userDefaultsSuites.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    private func makeModelDirectory(filenames: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeBootstrapModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        for filename in filenames {
            try Data("not a real model".utf8).write(to: directory.appendingPathComponent(filename))
        }
        return directory
    }

    private func removeModelFile(_ filename: String, in directory: URL) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "io.cotabby.tests.RuntimeBootstrapModelTests-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected an isolated UserDefaults suite")
            return .standard
        }
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaultsSuites.append((suiteName: suiteName, userDefaults: userDefaults))
        return userDefaults
    }

    @MainActor
    private func makeModel(modelDirectory: URL, userDefaults: UserDefaults) -> RuntimeBootstrapModel {
        // An empty preferred list keeps discovery ordering purely alphabetical, so tests can
        // reason about "the first available model" without referencing the shipping catalog.
        let configuration = LlamaRuntimeConfiguration(
            runtimeDirectoryPath: modelDirectory.path,
            preferredModelNames: [],
            contextWindowTokens: 512,
            batchSize: 128,
            gpuLayerCount: 0
        )
        let manager = LlamaRuntimeManager(
            configuration: configuration,
            runtimeLocator: BundledRuntimeLocator()
        )
        let model = RuntimeBootstrapModel(runtimeManager: manager, userDefaults: userDefaults)
        Self.retainedModels.append(model)
        return model
    }

    /// Subscribes to the model's state and fulfills once it first reports failure. Used to wait
    /// out the internal startup `Task` without sleeping.
    private func expectFailureState(of model: RuntimeBootstrapModel) -> (XCTestExpectation, AnyCancellable) {
        let failed = expectation(description: "runtime state reports failure")
        let cancellable = runOnMainActor {
            model.$state
                .compactMap { $0.failureDetail }
                .first()
                .sink { _ in failed.fulfill() }
        }
        return (failed, cancellable)
    }

    // MARK: - Initial selection

    func test_init_withoutModels_clearsSelectionAndStalePersistedValue() throws {
        let directory = try makeModelDirectory(filenames: [])
        let userDefaults = makeUserDefaults()
        userDefaults.set("stale.gguf", forKey: Self.selectionKey)

        runOnMainActor {
            let model = makeModel(modelDirectory: directory, userDefaults: userDefaults)

            XCTAssertTrue(model.availableModels.isEmpty)
            XCTAssertNil(model.selectedModelFilename)
            XCTAssertNil(userDefaults.string(forKey: Self.selectionKey), "Stale persisted choice must be cleared")
            XCTAssertEqual(model.state, .idle)
        }
    }

    func test_init_prefersPersistedSelectionWhenStillAvailable() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf", "beta.gguf"])
        let userDefaults = makeUserDefaults()
        userDefaults.set("beta.gguf", forKey: Self.selectionKey)

        runOnMainActor {
            let model = makeModel(modelDirectory: directory, userDefaults: userDefaults)

            XCTAssertEqual(model.availableModels.map(\.filename), ["alpha.gguf", "beta.gguf"])
            XCTAssertEqual(model.selectedModelFilename, "beta.gguf")
            XCTAssertEqual(userDefaults.string(forKey: Self.selectionKey), "beta.gguf")
        }
    }

    func test_init_fallsBackToFirstModelWhenPersistedSelectionIsGone() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf", "beta.gguf"])
        let userDefaults = makeUserDefaults()
        userDefaults.set("ghost.gguf", forKey: Self.selectionKey)

        runOnMainActor {
            let model = makeModel(modelDirectory: directory, userDefaults: userDefaults)

            XCTAssertEqual(model.selectedModelFilename, "alpha.gguf")
            XCTAssertEqual(
                userDefaults.string(forKey: Self.selectionKey),
                "alpha.gguf",
                "The repaired selection must be re-persisted"
            )
        }
    }

    // MARK: - startIfNeeded

    func test_startIfNeeded_withoutModels_staysIdle() throws {
        let directory = try makeModelDirectory(filenames: [])
        let userDefaults = makeUserDefaults()

        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }
        runOnMainActor { model.startIfNeeded() }

        // Give any (incorrectly) spawned startup task a chance to run: a regression here would
        // surface as a .failed state because the empty directory cannot resolve a model.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        runOnMainActor {
            XCTAssertEqual(model.state, .idle)
        }
    }

    func test_startIfNeeded_reportsFailureWhenSelectedModelDisappears() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }
        try removeModelFile("alpha.gguf", in: directory)

        let (failed, cancellable) = expectFailureState(of: model)
        runOnMainActor {
            model.startIfNeeded()
            // The duplicate call must be swallowed while the first startup task is in flight.
            model.startIfNeeded()
        }
        wait(for: [failed], timeout: 10)
        cancellable.cancel()

        runOnMainActor {
            XCTAssertNotNil(model.state.failureDetail)
            XCTAssertNotNil(model.diagnostics.lastError, "Diagnostics must surface the resolution failure")
        }
    }

    // MARK: - selectModel

    func test_selectModel_ignoresUnknownFilename() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf", "beta.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }
        let reloads = ReloadCounter()
        runOnMainActor { model.onWillReloadModel = { reloads.increment() } }

        let done = expectation(description: "selectModel returned")
        Task { @MainActor in
            await model.selectModel("ghost.gguf")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        runOnMainActor {
            XCTAssertEqual(model.selectedModelFilename, "alpha.gguf")
            XCTAssertEqual(userDefaults.string(forKey: Self.selectionKey), "alpha.gguf")
            XCTAssertEqual(reloads.count, 0, "An ignored selection must not reset suggestion state")
            XCTAssertEqual(model.state, .idle)
        }
    }

    func test_selectModel_switchesPersistsAndSignalsReload() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf", "beta.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }
        let reloads = ReloadCounter()
        runOnMainActor { model.onWillReloadModel = { reloads.increment() } }

        // Deleting the files after discovery makes the subsequent load fail inside the locator,
        // keeping the test off the native llama.cpp path while the full selection flow still runs.
        try removeModelFile("alpha.gguf", in: directory)
        try removeModelFile("beta.gguf", in: directory)

        let done = expectation(description: "selectModel returned")
        Task { @MainActor in
            await model.selectModel("beta.gguf")
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        runOnMainActor {
            XCTAssertEqual(model.selectedModelFilename, "beta.gguf")
            XCTAssertEqual(userDefaults.string(forKey: Self.selectionKey), "beta.gguf")
            XCTAssertEqual(reloads.count, 1, "Suggestion state must be told before the runtime reloads")
            XCTAssertNotNil(model.state.failureDetail, "The vanished file should surface as a failed load")
        }
    }

    // MARK: - Available-model reconciliation

    func test_refreshAvailableModels_discoversNewModelsAndKeepsValidSelection() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }

        try Data("not a real model".utf8).write(to: directory.appendingPathComponent("beta.gguf"))
        runOnMainActor { model.refreshAvailableModels() }

        runOnMainActor {
            XCTAssertEqual(model.availableModels.map(\.filename), ["alpha.gguf", "beta.gguf"])
            XCTAssertEqual(model.selectedModelFilename, "alpha.gguf", "A still-valid selection must not churn")
            XCTAssertEqual(userDefaults.string(forKey: Self.selectionKey), "alpha.gguf")
        }
    }

    func test_refreshAvailableModels_fallsBackToPersistedSelectionWhenCurrentDisappears() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf", "bravo.gguf", "charlie.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }
        runOnMainActor {
            XCTAssertEqual(model.selectedModelFilename, "alpha.gguf")
        }

        // The user's persisted intent (charlie) must beat "first remaining" (bravo) once the
        // current selection vanishes from disk.
        try removeModelFile("alpha.gguf", in: directory)
        userDefaults.set("charlie.gguf", forKey: Self.selectionKey)
        runOnMainActor { model.refreshAvailableModels() }

        runOnMainActor {
            XCTAssertEqual(model.availableModels.map(\.filename), ["bravo.gguf", "charlie.gguf"])
            XCTAssertEqual(model.selectedModelFilename, "charlie.gguf")
            XCTAssertEqual(userDefaults.string(forKey: Self.selectionKey), "charlie.gguf")
        }
    }

    func test_refreshAvailableModels_fallsBackToFirstRemainingModel() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf", "beta.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }

        // Both the current selection and the persisted value point at the vanished alpha.
        try removeModelFile("alpha.gguf", in: directory)
        runOnMainActor { model.refreshAvailableModels() }

        runOnMainActor {
            XCTAssertEqual(model.selectedModelFilename, "beta.gguf")
            XCTAssertEqual(userDefaults.string(forKey: Self.selectionKey), "beta.gguf")
        }
    }

    func test_refreshAvailableModels_clearsSelectionWhenAllModelsDisappear() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }

        try removeModelFile("alpha.gguf", in: directory)
        runOnMainActor { model.refreshAvailableModels() }

        runOnMainActor {
            XCTAssertTrue(model.availableModels.isEmpty)
            XCTAssertNil(model.selectedModelFilename)
            XCTAssertNil(userDefaults.string(forKey: Self.selectionKey))
        }
    }

    // MARK: - Shutdown forwarding

    func test_stop_returnsRuntimeToIdleAfterFailure() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }
        try removeModelFile("alpha.gguf", in: directory)

        let (failed, cancellable) = expectFailureState(of: model)
        runOnMainActor { model.startIfNeeded() }
        wait(for: [failed], timeout: 10)
        cancellable.cancel()

        runOnMainActor {
            model.stop()

            XCTAssertEqual(model.state, .idle)
            XCTAssertEqual(model.diagnostics.lastLoadStatus, "Stopped")
        }
    }

    func test_stopAndWait_completesWhenNothingWasLoaded() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }

        let done = expectation(description: "stopAndWait returned")
        Task { @MainActor in
            await model.stopAndWait()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        runOnMainActor {
            XCTAssertEqual(model.state, .idle)
            XCTAssertEqual(model.diagnostics.lastLoadStatus, "Stopped")
        }
    }

    func test_shutdownSync_returnsPromptlyWhenRuntimeNeverLoaded() throws {
        let directory = try makeModelDirectory(filenames: ["alpha.gguf"])
        let userDefaults = makeUserDefaults()
        let model = runOnMainActor { makeModel(modelDirectory: directory, userDefaults: userDefaults) }

        runOnMainActor {
            model.shutdownSync(timeoutSeconds: 2.0)

            XCTAssertEqual(model.state, .idle)
            XCTAssertEqual(model.diagnostics.lastLoadStatus, "Stopped")
        }
    }
}

/// Reference-typed counter so `onWillReloadModel` invocations stay observable from outside the
/// closure without capturing a mutable local in an escaping context.
private final class ReloadCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func runOnMainActor<Result>(
    _ body: @MainActor () throws -> Result
) rethrows -> Result {
    if Thread.isMainThread {
        return try MainActor.assumeIsolated(body)
    }

    return try DispatchQueue.main.sync {
        try MainActor.assumeIsolated(body)
    }
}
