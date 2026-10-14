import XCTest
@testable import Cotabby

/// Builds real fixture trees in a temp folder shaped like huggingface_hub's cache
/// (models--o--n/{blobs,refs,snapshots/<rev>}) and checks which repos count as usable MLX models.
final class MLXCacheScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes one cached repo. `files` maps snapshot file names to contents.
    @discardableResult
    private func repo(
        _ folder: String,
        revision: String = "rev1",
        refsMain: Bool = true,
        files: [String: String],
        incompleteBlob: Bool = false
    ) throws -> URL {
        let repo = root.appendingPathComponent(folder, isDirectory: true)
        let snapshot = repo.appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: snapshot.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        if refsMain {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
            try revision.write(to: repo.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        }
        if incompleteBlob {
            try "partial".write(to: repo.appendingPathComponent("blobs/abc.incomplete"), atomically: true, encoding: .utf8)
        }
        return repo
    }

    private func modelFiles(type: String, architectures: String = "[\"X\"]") -> [String: String] {
        [
            "config.json": "{\"model_type\":\"\(type)\",\"architectures\":\(architectures)}",
            "model.safetensors": "weights",
            "tokenizer.json": "{}"
        ]
    }

    func test_qualifyingModelIsListedWithTypeAndSize() throws {
        try repo("models--mlx-community--gemma-4-e4b-5bit", files: modelFiles(type: "gemma4"))
        let models = MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"])
        XCTAssertEqual(models.map(\.repoID.value), ["mlx-community/gemma-4-e4b-5bit"])
        XCTAssertEqual(models.first?.modelType, "gemma4")
        XCTAssertGreaterThan(models.first?.sizeBytes ?? 0, 0)
        XCTAssertEqual(models.first?.isInstruct, false)
    }

    /// A file still downloading has an `.incomplete` blob and no snapshot link yet, so the snapshot
    /// misses it. An unrelated partial blob (another revision, an unused file) must not hide a
    /// complete snapshot.
    func test_incompleteBlobsMatterOnlyThroughTheSnapshot() throws {
        var downloading = modelFiles(type: "gemma4"); downloading["model.safetensors"] = nil
        try repo("models--a--partial", files: downloading, incompleteBlob: true)
        try repo("models--a--complete", files: modelFiles(type: "gemma4"), incompleteBlob: true)
        XCTAssertEqual(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"]).map(\.repoID.value),
                       ["a/complete"])
    }

    /// A download stopped between shards leaves the config, the tokenizer and some shards: the
    /// index names a shard that is not there, so the model is not downloaded.
    func test_shardedModelNeedsEveryShardTheIndexNames() throws {
        var files = modelFiles(type: "gemma4"); files["model.safetensors"] = nil
        files["model.safetensors.index.json"] = """
        {"weight_map": {"a": "model-00001-of-00002.safetensors", "b": "model-00002-of-00002.safetensors"}}
        """
        files["model-00001-of-00002.safetensors"] = "w1"
        try repo("models--a--sharded", files: files)
        XCTAssertTrue(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"]).isEmpty)

        files["model-00002-of-00002.safetensors"] = "w2"
        try repo("models--a--sharded", files: files)
        XCTAssertEqual(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"]).count, 1)
    }

    /// A snapshot link whose blob was deleted cannot be loaded.
    func test_danglingSnapshotLinkIsNotDownloaded() throws {
        let repoURL = try repo("models--a--dangling", files: modelFiles(type: "gemma4"))
        let weights = repoURL.appendingPathComponent("snapshots/rev1/model.safetensors")
        try FileManager.default.removeItem(at: weights)
        try FileManager.default.createSymbolicLink(
            atPath: weights.path, withDestinationPath: "../../blobs/gone")
        XCTAssertTrue(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"]).isEmpty)
    }

    func test_missingWeightsOrTokenizerIsSkipped() throws {
        var noWeights = modelFiles(type: "gemma4"); noWeights["model.safetensors"] = nil
        try repo("models--a--noweights", files: noWeights)
        var noTokenizer = modelFiles(type: "gemma4"); noTokenizer["tokenizer.json"] = nil
        try repo("models--a--notok", files: noTokenizer)
        XCTAssertTrue(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"]).isEmpty)
    }

    func test_embeddingRerankerAndSpeechReposAreSkipped() throws {
        try repo("models--mlx-community--Qwen3-Embedding-0.6B-8bit", files: modelFiles(type: "qwen3"))
        try repo("models--mlx-community--Qwen3-TTS-12Hz-1.7B-Base-bf16", files: modelFiles(type: "qwen3"))
        try repo("models--a--plain", files: modelFiles(type: "qwen3", architectures: "[\"BertForSequenceClassification\"]"))
        XCTAssertTrue(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["qwen3"]).isEmpty)
    }

    func test_detailedScanReportsRejectedRepos() throws {
        try repo("models--mlx-community--Qwen3-Embedding-0.6B-8bit", files: modelFiles(type: "qwen3"))
        try repo("models--mlx-community--Qwen3-TTS-12Hz-1.7B-Base-bf16", files: modelFiles(type: "qwen3"))
        // Still downloading: the weights blob is `.incomplete` and not linked into the snapshot yet.
        var downloading = modelFiles(type: "qwen3"); downloading["model.safetensors"] = nil
        try repo("models--a--partial", files: downloading, incompleteBlob: true)
        try repo("models--a--ok", files: modelFiles(type: "qwen3"))
        let result = MLXCacheScanner.scanDetailed(cacheRoot: root, supportedModelTypes: ["qwen3"])
        XCTAssertEqual(result.models.map(\.repoID.value), ["a/ok"])
        XCTAssertEqual(result.rejected[MLXRepoID("mlx-community/Qwen3-Embedding-0.6B-8bit")!], .embeddingModel)
        XCTAssertEqual(result.rejected[MLXRepoID("mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16")!], .speechModel)
        XCTAssertNil(result.rejected[MLXRepoID("a/partial")!], "an incomplete download is just not downloaded")
    }

    func test_partialSnapshotsAreNeitherListedNorRejected() throws {
        try repo("models--a--configonly", files: ["config.json": "{\"model_type\":\"qwen3\"}"])
        var noTokenizer = modelFiles(type: "qwen3"); noTokenizer["tokenizer.json"] = nil
        try repo("models--a--notok", files: noTokenizer)
        let result = MLXCacheScanner.scanDetailed(cacheRoot: root, supportedModelTypes: ["qwen3"])
        XCTAssertTrue(result.models.isEmpty)
        XCTAssertTrue(result.rejected.isEmpty)
        XCTAssertEqual(
            MLXServerDesireResolver.desire(for: .init(
                engine: .mlx, isAppleSilicon: true,
                toolchain: .ready(MLXToolchain(
                    serverExecutable: URL(fileURLWithPath: "/s"), pythonExecutable: URL(fileURLWithPath: "/p"),
                    version: "0.32.0", isCotabbyInstall: true)),
                modelID: "a/configonly", cachedModels: result.models, promptCacheBytes: 1 << 30,
                rejectedModels: result.rejected)),
            .unavailable(.modelNotDownloaded(MLXRepoID("a/configonly")!)))
    }

    func test_unsupportedModelTypeIsSkippedUnlessTheSetIsUnknown() throws {
        try repo("models--a--odd", files: modelFiles(type: "whisper_like"))
        XCTAssertTrue(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"]).isEmpty)
        // Before mlx-lm is installed the supported set is unknown; models are listed unfiltered.
        XCTAssertEqual(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: nil).count, 1)
    }

    func test_instructNamesAreMarked() throws {
        try repo("models--mlx-community--gemma-4-e4b-it-4bit", files: modelFiles(type: "gemma4"))
        try repo("models--mlx-community--Llama-3.2-3B-Instruct-4bit", files: modelFiles(type: "llama"))
        let models = MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4", "llama"])
        XCTAssertEqual(models.filter(\.isInstruct).count, 2)
        XCTAssertFalse(MLXCacheScanner.isInstructName("gemma-4-e4b-5bit"))
        XCTAssertFalse(MLXCacheScanner.isInstructName("unit-test"), "'it' must be a whole token")
    }

    /// The server loads the repo id offline, which huggingface_hub resolves through `refs/main`. A
    /// snapshot without it (cached by commit) could not be loaded, so it is not downloaded.
    func test_onlyTheSnapshotRefsMainNamesCounts() throws {
        let folder = "models--a--revs"
        try repo(folder, revision: "new", refsMain: false, files: modelFiles(type: "gemma4"))
        XCTAssertTrue(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"]).isEmpty,
                      "no refs/main: the offline server could not resolve the repo")

        try repo(folder, revision: "old", files: ["config.json": "{}"])
        XCTAssertTrue(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"]).isEmpty,
                      "refs/main points at the snapshot without weights")

        try "new".write(to: root.appendingPathComponent("\(folder)/refs/main"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MLXCacheScanner.scan(cacheRoot: root, supportedModelTypes: ["gemma4"])
            .first?.snapshotURL.lastPathComponent, "new")
    }

    func test_cacheRootFollowsHuggingFaceEnvironment() {
        let home = URL(fileURLWithPath: "/Users/u")
        XCTAssertEqual(MLXCacheScanner.cacheRoot(environment: [:], home: home).path, "/Users/u/.cache/huggingface/hub")
        XCTAssertEqual(MLXCacheScanner.cacheRoot(environment: ["HF_HOME": "/hf"], home: home).path, "/hf/hub")
        XCTAssertEqual(MLXCacheScanner.cacheRoot(environment: ["HF_HOME": "/hf", "HF_HUB_CACHE": "/cache"], home: home).path, "/cache")
    }

    func test_downloadProgressCountsIncompleteBlobs() throws {
        let id = MLXRepoID("a/b")!
        let blobs = root.appendingPathComponent("models--a--b/blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data(count: 300).write(to: blobs.appendingPathComponent("x"))
        try Data(count: 200).write(to: blobs.appendingPathComponent("y.incomplete"))
        XCTAssertEqual(MLXCacheScanner.downloadedBytes(repo: id, cacheRoot: root), 500)
        XCTAssertEqual(MLXCacheScanner.progress(downloadedBytes: 500, totalBytes: 1000), 0.5)
        XCTAssertEqual(MLXCacheScanner.progress(downloadedBytes: 1500, totalBytes: 1000), 1.0)
        XCTAssertNil(MLXCacheScanner.progress(downloadedBytes: 1, totalBytes: 0))
    }
}
