import XCTest
@testable import Cotabby

/// File overview:
/// Pins the second MLX server's controller: it refuses to launch anything the resolver would not
/// launch (with the reason as the error), becomes ready on the fake launcher/probe, restarts on a
/// model change, and stops itself after the idle window. No Python runs; the manager's launcher
/// and probe are the doubles from `MLXServerManagerTests`.
@MainActor
final class MLXRewriteServerControllerTests: XCTestCase {
    private static var retained: [AnyObject] = []

    private let modelA = "mlx-community/gemma-4-e4b-it-4bit"
    private let modelB = "mlx-community/other-it"

    private var launcher: MLXFakeLauncher!
    private var probe: MLXFakeProbe!
    private var manager: MLXServerManager!
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-rewrite-\(UUID().uuidString)")
        launcher = MLXFakeLauncher()
        probe = MLXFakeProbe()
        manager = MLXServerManager(
            paths: MLXPaths(root: root), launcher: launcher, probe: probe, pickPort: { 50200 },
            sleep: { _ in await Task.yield() }, baseEnvironment: [:],
            verifyListener: { _, _ in true }, pidFileURL: MLXPaths(root: root).rewriteServerPIDFile)
        Self.retained.append(contentsOf: [launcher!, probe!, manager!] as [AnyObject])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var toolchain: MLXToolchainState {
        .ready(MLXToolchain(
            serverExecutable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"),
            pythonExecutable: URL(fileURLWithPath: "/mlx/bin/python"), version: "0.32.0", isCotabbyInstall: true))
    }

    private func cached(_ id: String) -> MLXCachedModel {
        MLXCachedModel(repoID: MLXRepoID(id)!, snapshotURL: root, sizeBytes: 1, modelType: "gemma4", isInstruct: true)
    }

    private func makeController(
        toolchain: MLXToolchainState? = nil,
        cachedIDs: [String]? = nil,
        rejected: [MLXRepoID: MLXModelCompatibility.Reason] = [:],
        sleep: MLXRewriteServerController.Sleep? = nil
    ) -> MLXRewriteServerController {
        let state = toolchain ?? self.toolchain
        let models = (cachedIDs ?? [modelA, modelB]).map(cached)
        let controller = MLXRewriteServerController(
            manager: manager,
            toolchain: { state },
            cachedModels: { models },
            rejectedModels: { rejected },
            isAppleSilicon: true,
            sleep: sleep ?? { _ in await Task.yield() })
        Self.retained.append(controller)
        return controller
    }

    private func becomeReady() async {
        await waitUntil { self.probe.waiting >= 1 }
        probe.succeedNext()
    }

    func test_notInstalledThrowsTheReasonWithoutLaunching() async {
        let controller = makeController(toolchain: .notInstalled)
        do {
            _ = try await controller.readyConfiguration(modelID: modelA)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable(MLXUnavailableReason.notInstalled.message))
        }
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func test_notDownloadedThrowsWithoutLaunching() async {
        let controller = makeController(cachedIDs: [modelB])
        do {
            _ = try await controller.readyConfiguration(modelID: modelA)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable(MLXUnavailableReason.modelNotDownloaded(MLXRepoID(modelA)!).message))
        }
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertFalse(controller.canRun(modelID: modelA))
    }

    func test_incompatibleModelThrowsWithoutLaunching() async {
        let reason = MLXModelCompatibility.Reason.unsupportedArchitecture("foo")
        // A rejected model is absent from the cache list the resolver sees.
        let controller = makeController(cachedIDs: [], rejected: [MLXRepoID(modelA)!: reason])
        do {
            _ = try await controller.readyConfiguration(modelID: modelA)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable(MLXUnavailableReason.modelIncompatible(MLXRepoID(modelA)!, reason.message).message))
        }
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func test_launchesTheChatModelWithASmallCacheAndReturnsItsEndpoint() async throws {
        let controller = makeController()
        async let configuration = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        let ready = try await configuration
        XCTAssertEqual(ready.modelName, modelA)
        XCTAssertEqual(ready.baseURL.absoluteString, "http://127.0.0.1:50200/v1")
        let arguments = launcher.launches[0].arguments
        let cacheIndex = try XCTUnwrap(arguments.firstIndex(of: "--prompt-cache-bytes"))
        XCTAssertEqual(arguments[cacheIndex + 1], String(512 << 20))
    }

    func test_aFailedServerThrowsItsReason() async {
        let controller = makeController()
        let task = Task { try await controller.readyConfiguration(modelID: modelA) }
        await waitUntil { self.probe.waiting >= 1 }
        // Three crashes in a row exhaust the restart policy and publish .failed.
        for index in 0..<3 {
            launcher.crash(index)
            if index < 2 {
                await waitUntil { self.launcher.launches.count == index + 2 }
            }
        }
        do {
            _ = try await task.value
            XCTFail("expected an error")
        } catch {
            guard case .unavailable = error as? RewriteError else { return XCTFail("wrong error \(error)") }
        }
    }

    func test_changingTheModelRestartsOnTheNextUse() async throws {
        let controller = makeController()
        async let first = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        _ = try await first
        async let second = controller.readyConfiguration(modelID: modelB)
        await waitUntil { self.launcher.launches.count == 2 }
        await becomeReady()
        let ready = try await second
        XCTAssertEqual(ready.modelName, modelB)
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
    }

    func test_idleTimerStopsTheServer() async throws {
        let gate = SleepGate()
        let controller = makeController(sleep: { duration in
            if duration >= .seconds(60) { await gate.pause() } else { await Task.yield() }
        })
        async let configuration = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        _ = try await configuration
        controller.beginUse()
        controller.endUse()
        await waitUntil { gate.count >= 1 }
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 0)
        gate.releaseAll()
        await waitUntil { self.manager.state == .idle }
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
    }

    func test_noteUseAgainRestartsTheIdleWindow() async throws {
        let gate = SleepGate()
        let controller = makeController(sleep: { duration in
            if duration >= .seconds(60) { await gate.pause() } else { await Task.yield() }
        })
        async let configuration = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        _ = try await configuration
        controller.beginUse()
        controller.endUse()
        await waitUntil { gate.count >= 1 }
        controller.beginUse()
        controller.endUse()
        // The first timer was cancelled; releasing it must not stop the server (its task is cancelled
        // by then, so the stale wake-up is ignored).
        gate.releaseAll()
        await Task.yield()
        await Task.yield()
        if case .ready = manager.state {} else { XCTFail("server stopped by a stale idle timer: \(manager.state)") }
    }

    func test_stopStopsTheServer() async throws {
        let controller = makeController()
        async let configuration = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        _ = try await configuration
        await controller.stop()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
    }

    /// A Settings change (provider, engine, model) asks for a stop; a rewrite still streaming on the
    /// server finishes first instead of failing with a dropped connection.
    func test_stopWaitsForARewriteInFlight() async throws {
        let controller = makeController()
        async let configuration = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        _ = try await configuration
        controller.beginUse()
        let stopReturned = StopFlag()
        Task {
            await controller.stop()
            stopReturned.isSet = true
        }
        for _ in 0..<5 { await Task.yield() }
        if case .ready = manager.state {} else { XCTFail("stopped under a running rewrite: \(manager.state)") }
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 0)
        XCTAssertFalse(stopReturned.isSet, "a deferred stop returns only once the server is down")
        controller.endUse()
        await waitUntil { stopReturned.isSet }
        XCTAssertEqual(manager.state, .idle, "the caller may start another server on the same model now")
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
    }

    /// A Settings change that was undone while a rewrite was still running: the next rewrite wants the
    /// server, so the deferred stop is dropped and the server keeps running for it.
    func test_aLaterStartCancelsADeferredStop() async throws {
        // The idle timer waits on a gate, so only a deferred stop could stop the server here.
        let gate = SleepGate()
        let controller = makeController(sleep: { duration in
            if duration >= .seconds(60) { await gate.pause() } else { await Task.yield() }
        })
        async let first = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        _ = try await first
        controller.beginUse()
        let stopReturned = StopFlag()
        Task {
            await controller.stop()
            stopReturned.isSet = true
        }
        for _ in 0..<5 { await Task.yield() }
        controller.beginUse()
        _ = try await controller.readyConfiguration(modelID: modelA)
        await waitUntil { stopReturned.isSet }
        controller.endUse()
        controller.endUse()
        for _ in 0..<5 { await Task.yield() }
        if case .ready = manager.state {} else { XCTFail("a dropped stop still ran: \(manager.state)") }
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 0)
    }

    func test_quittingReleasesAWaitOnADeferredStop() async throws {
        let controller = makeController()
        async let configuration = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        _ = try await configuration
        controller.beginUse()
        let stopReturned = StopFlag()
        Task {
            await controller.stop()
            stopReturned.isSet = true
        }
        for _ in 0..<5 { await Task.yield() }
        controller.prepareForShutdown()
        await waitUntil { stopReturned.isSet }
    }

    func test_canRunMatchesTheResolver() {
        XCTAssertTrue(makeController().canRun(modelID: modelA))
        XCTAssertFalse(makeController(toolchain: .notInstalled).canRun(modelID: modelA))
    }

    func test_shutdownSyncStopsTheServerAndBlocksLaterStarts() async throws {
        let controller = makeController()
        async let configuration = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        _ = try await configuration
        controller.shutdownSync(timeoutSeconds: 1)
        XCTAssertEqual(launcher.launches[0].process.terminateCount, 1)
        do {
            _ = try await controller.readyConfiguration(modelID: modelA)
            XCTFail("expected an error after shutdown")
        } catch {
            XCTAssertEqual(launcher.launches.count, 1)
        }
    }

    func test_aFailedServerIsRetriedByTheNextRewrite() async throws {
        let controller = makeController()
        let failing = Task { try await controller.readyConfiguration(modelID: modelA) }
        await waitUntil { self.probe.waiting >= 1 }
        for index in 0..<3 {
            launcher.crash(index)
            if index < 2 { await waitUntil { self.launcher.launches.count == index + 2 } }
        }
        _ = await failing.result
        guard case .failed = manager.state else { return XCTFail("expected failed, got \(manager.state)") }
        let launchesBefore = launcher.launches.count
        async let retry = controller.readyConfiguration(modelID: modelA)
        await waitUntil { self.launcher.launches.count == launchesBefore + 1 }
        // The crashed launches' readiness waits are still pending in the fake; their generations are
        // stale, so resolving them is ignored. The newest wait is the last one.
        await waitUntil { self.probe.waiting >= 4 }
        while probe.waiting > 1 { probe.succeedNext() }
        probe.succeedNext()
        let ready = try await retry
        XCTAssertEqual(ready.modelName, modelA)
    }

    func test_idleTimerWaitsWhileARewriteIsInFlight() async throws {
        let gate = SleepGate()
        let controller = makeController(sleep: { duration in
            if duration >= .seconds(60) { await gate.pause() } else { await Task.yield() }
        })
        async let configuration = controller.readyConfiguration(modelID: modelA)
        await becomeReady()
        _ = try await configuration
        controller.beginUse()
        controller.endUse()
        await waitUntil { gate.count >= 1 }
        // A second rewrite begins while the timer is pending: the timer is cancelled and re-armed
        // only when that rewrite ends, so a long rewrite is never stopped under itself.
        controller.beginUse()
        gate.releaseAll()
        await Task.yield()
        await Task.yield()
        if case .ready = manager.state {} else { XCTFail("stopped during a rewrite: \(manager.state)") }
        controller.endUse()
        await waitUntil { gate.count >= 1 }
        gate.releaseAll()
        await waitUntil { self.manager.state == .idle }
    }

    func test_invalidStoredModelIdFailsAtOnce() async {
        let controller = makeController()
        do {
            _ = try await controller.readyConfiguration(modelID: "../../etc")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable(MLXUnavailableReason.noModel.message))
        }
        XCTAssertTrue(launcher.launches.isEmpty)
    }

    func test_unavailableReasonExplainsWhyAndIsNilWhenRunnable() {
        XCTAssertNil(makeController().unavailableReason(modelID: modelA))
        XCTAssertEqual(makeController(toolchain: .notInstalled).unavailableReason(modelID: modelA),
                       MLXUnavailableReason.notInstalled.message)
    }
}

/// Set when a `stop()` call returns, read from the test on the main actor.
@MainActor
private final class StopFlag {
    var isSet = false

    // Released at the end of each test; a MainActor deinit would go through the back-deployment
    // executor shim that double-frees on a macOS 26 runtime.
    nonisolated deinit {}
}
