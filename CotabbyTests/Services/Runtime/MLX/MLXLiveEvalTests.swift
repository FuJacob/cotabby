#if RUN_MLX_EVAL
import XCTest
@testable import Cotabby

/// File overview:
/// The only test that starts a real `mlx_lm.server`. It is compiled and run only with the
/// `RUN_MLX_EVAL` flag, in Release, on a Mac that has mlx-lm and the model in its Hugging Face
/// cache. It walks the same path the app walks: find the toolchain, check the cache, apply the
/// desire, wait for readiness, stream a completion through the engine, then stop and confirm no
/// process is left. Fakes are deliberately absent here, because the point is to prove the real
/// socket check and the real process lifecycle.
@MainActor
final class MLXLiveEvalTests: XCTestCase {
    /// Keeps the collaborators alive for the whole run, the same pattern the other MLX test classes
    /// use, so no object is released while the server is still starting or generating.
    private static var retained: [AnyObject] = []

    func test_liveServerGeneratesAndStopsCleanly() async throws {
        let modelID = ProcessInfo.processInfo.environment["MLX_EVAL_MODEL"] ?? "mlx-community/gemma-4-e4b-5bit"
        let paths = MLXPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mlx-live-\(UUID().uuidString)"))
        let provisioner = MLXToolchainProvisioner.live(paths: MLXPaths.standard())
        let manager = MLXServerManager.live(paths: paths)
        let downloader = MLXModelDownloader.live()
        let client = OpenAICompatibleAPIClient()
        let engine = OpenAICompatibleSuggestionEngine.mlx(client: client, serverManager: manager)
        Self.retained.append(contentsOf: [provisioner, manager, downloader, client, engine] as [AnyObject])

        await provisioner.refresh()
        let toolchain = try XCTUnwrap(provisioner.state.toolchain, "mlx-lm is not installed: \(provisioner.state)")
        await downloader.refreshCache(toolchain: toolchain)
        let desire = MLXServerDesireResolver.desire(for: .init(
            engine: .mlx, isAppleSilicon: true, toolchain: provisioner.state, modelID: modelID,
            cachedModels: downloader.cachedModels, promptCacheBytes: 1 << 30))
        guard case .running = desire else { return XCTFail("cannot run: \(desire)") }

        let started = Date()
        await manager.apply(desire)
        await waitUntil(timeout: 150) {
            if case .ready = manager.state { return true }
            if case .failed = manager.state { return true }
            return false
        }
        guard case .ready = manager.state else { return XCTFail("server: \(manager.state)") }
        print("MLX ready after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        let pid = try XCTUnwrap(MLXServerPIDFile(url: paths.serverPIDFile).read())

        var partials = 0
        var latencies: [Int] = []
        for prefix in ["Thanks for the update. I will send the", "The meeting is moved to Thursday because"] {
            let request = CotabbyTestFixtures.suggestionRequest(prefixText: prefix, prompt: prefix)
            let begin = Date()
            let result = try await engine.generateSuggestion(for: request, onPartial: { _ in partials += 1 })
            latencies.append(Int(Date().timeIntervalSince(begin) * 1000))
            XCTAssertFalse(result.rawText.isEmpty, "empty completion for \(prefix)")
            print("MLX: \(prefix)|\(result.rawText)|")
        }
        print("MLX latencies ms: \(latencies)")
        XCTAssertLessThan(latencies[0], 3000, "first suggestion after readiness should not pay the cold-start cost")
        XCTAssertGreaterThan(partials, 0, "the stream reported no partials")

        await manager.apply(.stopped)
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(MLXProcessInspector.isAlive(pid), "mlx_lm.server \(pid) is still running")
        try? FileManager.default.removeItem(at: paths.root)
    }
}
#endif
