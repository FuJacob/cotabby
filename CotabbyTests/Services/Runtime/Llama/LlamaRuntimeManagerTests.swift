import Combine
import Foundation
import XCTest
@testable import Cotabby

/// Drives the runtime manager's model-load lifecycle through a gated loader: sharing one load
/// between concurrent callers, replacing a load when the selected model changes, and above all
/// that a load the manager moved on from can never publish its late result.
@MainActor
final class LlamaRuntimeManagerTests: XCTestCase {
    private func makeManager(_ loader: GatedModelLoader) throws -> LlamaRuntimeManager {
        try loader.makeManager(in: makeTemporaryDirectory(), filenames: ["alpha.gguf", "beta.gguf"])
    }

    private func assertCancelled(
        _ task: Task<Void, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Expected the abandoned load to report cancellation", file: file, line: line)
        } catch LlamaRuntimeError.cancelled {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func test_prepare_loadsTheSelectedModelOnceAndReusesIt() async throws {
        let loader = GatedModelLoader()
        let manager = try makeManager(loader)

        try await manager.prepare()
        try await manager.prepare()

        XCTAssertEqual(loader.startedFilenames, ["alpha.gguf"])
        XCTAssertEqual(manager.state, .ready("Loaded alpha.gguf in-process."))
        XCTAssertEqual(manager.loadedModelFileURL?.lastPathComponent, "alpha.gguf")
    }

    func test_concurrentPreparesShareOneLoad() async throws {
        let loader = GatedModelLoader()
        loader.holdLoads()
        let manager = try makeManager(loader)

        let first = Task { try await manager.prepare() }
        let second = Task { try await manager.prepare() }
        try await loader.waitForStartedLoads(1)
        XCTAssertEqual(manager.state, .loading("Loading alpha.gguf into memory."))

        loader.release(call: 0)
        try await first.value
        try await second.value

        XCTAssertEqual(loader.startedFilenames, ["alpha.gguf"])
        XCTAssertEqual(manager.state, .ready("Loaded alpha.gguf in-process."))
    }

    /// Model loading does not observe cancellation, so the replaced load still finishes natively.
    /// Its result must not mark the old model ready or disturb the load that replaced it.
    func test_supersededLoadCannotPublishOverTheCurrentOne() async throws {
        let loader = GatedModelLoader()
        loader.holdLoads()
        let manager = try makeManager(loader)
        var states: [RuntimeBootstrapState] = []
        let observation = manager.$state.sink { states.append($0) }
        defer { observation.cancel() }

        let alphaLoad = Task { try await manager.prepare() }
        try await loader.waitForStartedLoads(1)
        manager.configureSelectedModel(filename: "beta.gguf")
        let betaLoad = Task { try await manager.prepare() }
        try await loader.waitForStartedLoads(2)

        loader.release(call: 0)
        await assertCancelled(alphaLoad)
        XCTAssertEqual(manager.state, .loading("Loading beta.gguf into memory."))

        loader.release(call: 1)
        try await betaLoad.value

        XCTAssertEqual(loader.startedFilenames, ["alpha.gguf", "beta.gguf"])
        XCTAssertEqual(manager.state, .ready("Loaded beta.gguf in-process."))
        XCTAssertFalse(states.contains(.ready("Loaded alpha.gguf in-process.")))
        XCTAssertEqual(manager.loadedModelFileURL?.lastPathComponent, "beta.gguf")
    }

    func test_supersededLoadFailureIsNotPublished() async throws {
        let loader = GatedModelLoader()
        loader.holdLoads()
        loader.failLoads(of: "alpha.gguf", message: "alpha is corrupt")
        let manager = try makeManager(loader)

        let alphaLoad = Task { try await manager.prepare() }
        try await loader.waitForStartedLoads(1)
        manager.configureSelectedModel(filename: "beta.gguf")
        let betaLoad = Task { try await manager.prepare() }
        try await loader.waitForStartedLoads(2)

        loader.release(call: 0)
        await assertCancelled(alphaLoad)
        XCTAssertEqual(manager.state, .loading("Loading beta.gguf into memory."))

        loader.release(call: 1)
        try await betaLoad.value
        XCTAssertEqual(manager.state, .ready("Loaded beta.gguf in-process."))
    }

    func test_stopDuringLoadKeepsTheRuntimeIdle() async throws {
        let loader = GatedModelLoader()
        loader.holdLoads()
        let manager = try makeManager(loader)

        let load = Task { try await manager.prepare() }
        try await loader.waitForStartedLoads(1)
        manager.stop()
        XCTAssertEqual(manager.state, .idle)

        loader.release(call: 0)
        await assertCancelled(load)

        XCTAssertEqual(manager.state, .idle, "A load that finishes after stop must not mark the runtime ready")
        XCTAssertNil(manager.loadedModelFileURL, "A load that finishes after stop must not be kept in memory")
    }

    func test_failedLoadReachesEveryWaiterAndAllowsARetry() async throws {
        let loader = GatedModelLoader()
        loader.holdLoads()
        loader.failLoads(of: "alpha.gguf", message: "alpha is corrupt")
        let manager = try makeManager(loader)
        var states: [RuntimeBootstrapState] = []
        let observation = manager.$state.sink { states.append($0) }
        defer { observation.cancel() }

        let first = Task { try await manager.prepare() }
        let second = Task { try await manager.prepare() }
        try await loader.waitForStartedLoads(1)
        loader.release(call: 0)

        for waiter in [first, second] {
            do {
                try await waiter.value
                XCTFail("Expected the load failure")
            } catch LlamaRuntimeError.unavailable(let message) {
                XCTAssertEqual(message, "alpha is corrupt")
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(manager.state, .failed("alpha is corrupt"))
        XCTAssertNil(manager.loadedModelFileURL)
        XCTAssertEqual(states.filter { $0 == .failed("alpha is corrupt") }.count, 1, "One load publishes one failure")

        let retry = Task { try await manager.prepare() }
        try await loader.waitForStartedLoads(2)
        loader.release(call: 1)
        _ = try? await retry.value
        XCTAssertEqual(loader.startedFilenames, ["alpha.gguf", "alpha.gguf"])
    }

    func test_selectModel_switchesModelsAndSkipsTheOneAlreadyLoaded() async throws {
        let loader = GatedModelLoader()
        let manager = try makeManager(loader)
        try await manager.prepare()

        try await manager.selectModel(filename: "beta.gguf")
        XCTAssertEqual(manager.currentModelFilename, "beta.gguf")
        XCTAssertEqual(manager.state, .ready("Loaded beta.gguf in-process."))

        try await manager.selectModel(filename: "beta.gguf")
        XCTAssertEqual(loader.startedFilenames, ["alpha.gguf", "beta.gguf"])
    }
}
