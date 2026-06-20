import XCTest
@testable import Cotabby

/// Tests the pure MLX runtime discovery and prompt-cache planning rules.
///
/// These belong in the test target rather than a runtime integration suite because neither concern
/// needs Metal, tokenizers, or an actual model load. That boundary keeps the MLX storage contract
/// easy to validate while the concrete backend adapter continues to evolve.
final class MlxRuntimeLocatorTests: XCTestCase {
    func test_discoverModelSnapshotURLs_requiresConfigTokenizerAndWeights() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let valid = root
            .appendingPathComponent("mlx-community", isDirectory: true)
            .appendingPathComponent("Tiny-4bit", isDirectory: true)
        let missingTokenizer = root.appendingPathComponent("missing-tokenizer", isDirectory: true)
        let missingWeights = root.appendingPathComponent("missing-weights", isDirectory: true)
        try makeSnapshot(at: valid)
        try makeSnapshot(at: missingTokenizer, includeTokenizer: false)
        try makeSnapshot(at: missingWeights, includeWeights: false)

        let discovered = MlxRuntimeLocator.discoverModelSnapshotURLs(in: root)

        XCTAssertEqual(discovered.map(\.standardizedFileURL), [valid.standardizedFileURL])
    }

    func test_availableModels_preservesHuggingFaceStyleIDsAndPreferredOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let qwen = root
            .appendingPathComponent("mlx-community", isDirectory: true)
            .appendingPathComponent("Qwen3-4B-4bit", isDirectory: true)
        let gemma = root
            .appendingPathComponent("mlx-community", isDirectory: true)
            .appendingPathComponent("gemma-3-1b-it-qat-4bit", isDirectory: true)
        try makeSnapshot(at: qwen)
        try makeSnapshot(at: gemma)

        let configuration = MlxRuntimeConfiguration(
            runtimeDirectoryPath: root.path,
            preferredModelIDs: ["mlx-community/gemma-3-1b-it-qat-4bit"],
            maxKVSize: nil,
            kvBits: nil,
            prefillStepSize: 256
        )

        let models = MlxRuntimeLocator().availableModels(configuration: configuration)

        XCTAssertEqual(
            models.map(\.id),
            [
                "mlx-community/gemma-3-1b-it-qat-4bit",
                "mlx-community/Qwen3-4B-4bit"
            ]
        )
    }

    func test_resolveUsesSelectedModelWhenAvailable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let flatModel = root.appendingPathComponent("LocalModel", isDirectory: true)
        try makeSnapshot(at: flatModel)
        let configuration = MlxRuntimeConfiguration(
            runtimeDirectoryPath: root.path,
            preferredModelIDs: [],
            maxKVSize: 1024,
            kvBits: 4,
            prefillStepSize: 128
        )

        let resolved = try MlxRuntimeLocator().resolve(
            configuration: configuration,
            selectedModelID: "LocalModel"
        )

        XCTAssertEqual(resolved.modelID, "LocalModel")
        XCTAssertEqual(resolved.modelDirectoryURL.standardizedFileURL, flatModel.standardizedFileURL)
    }

    func test_promptCachePlanner_reusesSharedPrefixWhenSamplingMatches() {
        let decision = MlxPromptCachePlanner.decision(
            cachedTokens: [1, 2, 3, 4],
            newTokens: [1, 2, 3, 9],
            cachedFingerprint: "same",
            newFingerprint: "same",
            cacheIsTrimmable: true
        )

        XCTAssertEqual(decision.action, .reuse(commonPrefixTokens: 3))
    }

    func test_promptCachePlanner_usesFreshCacheWhenSamplingChanges() {
        let decision = MlxPromptCachePlanner.decision(
            cachedTokens: [1, 2, 3],
            newTokens: [1, 2, 3],
            cachedFingerprint: "old",
            newFingerprint: "new",
            cacheIsTrimmable: true
        )

        XCTAssertEqual(decision.action, .fresh(reason: "sampling_changed"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotabby-mlx-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSnapshot(
        at directory: URL,
        includeTokenizer: Bool = true,
        includeWeights: Bool = true
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
        if includeTokenizer {
            try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        }
        if includeWeights {
            try Data([0x01, 0x02]).write(to: directory.appendingPathComponent("model.safetensors"))
        }
    }
}
