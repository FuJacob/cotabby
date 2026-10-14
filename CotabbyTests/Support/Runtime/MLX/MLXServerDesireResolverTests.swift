import XCTest
@testable import Cotabby

final class MLXServerDesireResolverTests: XCTestCase {
    private let toolchain = MLXToolchain(
        serverExecutable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"),
        pythonExecutable: URL(fileURLWithPath: "/mlx/python"),
        version: "0.32.0",
        isCotabbyInstall: true
    )
    private let model = MLXCachedModel(
        repoID: MLXRepoID("mlx-community/gemma-4-e4b-5bit")!, snapshotURL: URL(fileURLWithPath: "/c"),
        sizeBytes: 1, modelType: "gemma4", isInstruct: false
    )

    private func desire(
        engine: SuggestionEngineKind = .mlx,
        appleSilicon: Bool = true,
        toolchain: MLXToolchainState? = nil,
        modelID: String = "mlx-community/gemma-4-e4b-5bit",
        cached: [MLXCachedModel]?? = .none,
        rejected: [MLXRepoID: MLXModelCompatibility.Reason] = [:]
    ) -> MLXServerDesire {
        MLXServerDesireResolver.desire(
            engine: engine,
            isAppleSilicon: appleSilicon,
            toolchain: toolchain ?? .ready(self.toolchain),
            modelID: modelID,
            cachedModels: cached ?? [model],
            promptCacheBytes: 1 << 30,
            rejectedModels: rejected
        )
    }

    func test_selectedModelRejectedByCompatibilityIsIncompatibleNotMissing() {
        let id = MLXRepoID("a/embed")!
        XCTAssertEqual(
            desire(modelID: "a/embed", cached: [], rejected: [id: .embeddingModel]),
            .unavailable(.modelIncompatible(id, "Embedding model: it can't write text.")))
        XCTAssertEqual(desire(modelID: "a/embed", cached: []), .unavailable(.modelNotDownloaded(id)))
        XCTAssertEqual(
            MLXUnavailableReason.modelIncompatible(id, "x").message, "a/embed can't run on MLX: x")
    }

    func test_otherEnginesStopTheServer() {
        XCTAssertEqual(desire(engine: .llamaOpenSource), .stopped)
        XCTAssertEqual(desire(engine: .openAICompatible), .stopped)
    }

    func test_intelIsUnsupported() {
        XCTAssertEqual(desire(appleSilicon: false), .unavailable(.unsupportedHardware))
    }

    func test_toolchainStates() {
        XCTAssertEqual(desire(toolchain: .checking), .stopped)
        XCTAssertEqual(desire(toolchain: .installing(.installingMLX)), .stopped)
        XCTAssertEqual(desire(toolchain: .notInstalled), .unavailable(.notInstalled))
        XCTAssertEqual(desire(toolchain: .tooOld(version: "0.20.0", path: "/x")), .unavailable(.notInstalled))
        XCTAssertEqual(desire(toolchain: .failed(reason: "x", logTail: [])), .unavailable(.notInstalled))
    }

    func test_noOrInvalidModelIsNoModel() {
        XCTAssertEqual(desire(modelID: ""), .unavailable(.noModel))
        XCTAssertEqual(desire(modelID: "not a repo"), .unavailable(.noModel))
    }

    func test_cacheNotScannedYetWaits() {
        XCTAssertEqual(desire(cached: .some(nil)), .stopped)
    }

    /// Review focus 2.
    func test_selectedModelMissingFromCache_isModelNotDownloaded() {
        XCTAssertEqual(desire(cached: .some([])),
                       .unavailable(.modelNotDownloaded(MLXRepoID("mlx-community/gemma-4-e4b-5bit")!)))
    }

    func test_everythingPresentRunsTheServer() {
        XCTAssertEqual(desire(), .running(MLXServerLaunch(
            executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"),
            modelID: "mlx-community/gemma-4-e4b-5bit",
            promptCacheBytes: 1 << 30
        )))
    }
}
