import XCTest
@testable import Cotabby

@MainActor
final class MLXModelDownloaderTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private var cacheRoot: URL!
    private let toolchain = MLXToolchain(
        serverExecutable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"),
        pythonExecutable: URL(fileURLWithPath: "/mlx/python"),
        version: "0.32.0", isCotabbyInstall: true)

    override func setUpWithError() throws {
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    /// Writes a complete cached model the way huggingface_hub would leave it.
    private func writeCachedModel(_ id: String, type: String = "gemma4") throws {
        let repo = cacheRoot.appendingPathComponent(MLXRepoID(id)!.cacheFolderName)
        let snapshot = repo.appendingPathComponent("snapshots/rev")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("blobs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try "rev".write(to: repo.appendingPathComponent("refs/main"), atomically: true, encoding: .utf8)
        try "{\"model_type\":\"\(type)\"}".write(to: snapshot.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try "w".write(to: snapshot.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)
        try "{}".write(to: snapshot.appendingPathComponent("tokenizer.json"), atomically: true, encoding: .utf8)
    }

    private func makeDownloader(
        files: @escaping (String) async throws -> [HFRepoFile] = { _ in [] },
        gated: @escaping (String) async throws -> Bool = { _ in false },
        config: @escaping MLXModelDownloader.ConfigFetch = { _ in Data("{\"model_type\":\"gemma4\"}".utf8) },
        run: @escaping MLXModelDownloader.RunProcess = { _, _, _, _ in MLXProcessResult(status: 0, stdout: "[\"gemma4\"]", stderrTail: []) }
    ) -> MLXModelDownloader {
        let downloader = MLXModelDownloader(
            cacheRoot: cacheRoot, fileManager: .default,
            fetchRepoFiles: files, fetchIsGated: gated, fetchConfig: config, runProcess: run, pollInterval: .milliseconds(20))
        Self.retained.append(downloader)
        return downloader
    }

    func test_refreshFiltersByTheInstalledArchitectures() async throws {
        try writeCachedModel("a/gemma", type: "gemma4")
        try writeCachedModel("a/other", type: "mamba_x")
        let downloader = makeDownloader()
        XCTAssertNil(downloader.cachedModels, "nil until the first scan")
        await downloader.refreshCache(toolchain: toolchain)
        XCTAssertEqual(downloader.cachedModels?.map(\.repoID.value), ["a/gemma"])
        await downloader.refreshCache(toolchain: nil)
        XCTAssertEqual(downloader.cachedModels?.count, 2, "without mlx-lm the type filter is skipped")
    }

    func test_validationRejectsBadIDsWithoutNetwork() async {
        let downloader = makeDownloader(files: { _ in XCTFail("no network for a bad id"); return [] })
        let result = await downloader.validateCustomRepo("../../etc", toolchain: nil)
        XCTAssertEqual(result, .invalidID)
    }

    func test_validationClassifiesRepos() async {
        let missing = makeDownloader(files: { _ in throw HuggingFaceAPIClient.APIError.httpError(statusCode: 404) })
        let missingResult = await missing.validateCustomRepo("a/b", toolchain: nil)
        XCTAssertEqual(missingResult, .notFoundOrPrivate(MLXRepoID("a/b")!))

        let gated = makeDownloader(files: { _ in [HFRepoFile(path: "config.json", size: 1)] }, gated: { _ in true })
        let gatedResult = await gated.validateCustomRepo("a/b", toolchain: nil)
        XCTAssertEqual(gatedResult, .gated(MLXRepoID("a/b")!))

        let gguf = makeDownloader(files: { _ in [HFRepoFile(path: "config.json", size: 1), HFRepoFile(path: "m.gguf", size: 9)] })
        let ggufResult = await gguf.validateCustomRepo("a/b", toolchain: nil)
        XCTAssertEqual(ggufResult, .incompatible(MLXRepoID("a/b")!, .missingWeights))

        let good = makeDownloader(files: { _ in
            [HFRepoFile(path: "config.json", size: 1), HFRepoFile(path: "model.safetensors", size: 99),
             HFRepoFile(path: "tokenizer.json", size: 1)]
        })
        let goodResult = await good.validateCustomRepo("https://huggingface.co/a/b", toolchain: toolchain)
        XCTAssertEqual(goodResult, .valid(MLXRepoID("a/b")!, totalBytes: 101, isInstruct: false))
    }

    private let fullTree = [
        HFRepoFile(path: "config.json", size: 1), HFRepoFile(path: "model.safetensors", size: 9),
        HFRepoFile(path: "tokenizer.json", size: 1)
    ]

    func test_validationRejectsEmbeddingRepo() async {
        let tree = fullTree
        let d = makeDownloader(files: { _ in tree })
        let result = await d.validateCustomRepo("mlx-community/Qwen3-Embedding-0.6B", toolchain: nil)
        XCTAssertEqual(result, .incompatible(MLXRepoID("mlx-community/Qwen3-Embedding-0.6B")!, .embeddingModel))
    }

    func test_validationRejectsUnsupportedModelTypeWhenTheSetIsKnown() async {
        let tree = fullTree
        let d = makeDownloader(
            files: { _ in tree },
            config: { _ in Data("{\"model_type\":\"mamba_x\"}".utf8) })
        let result = await d.validateCustomRepo("a/b", toolchain: toolchain)
        XCTAssertEqual(result, .incompatible(MLXRepoID("a/b")!, .unsupportedArchitecture("mamba_x")))
    }

    func test_validationMarksInstructReposAndMapsConfig404() async {
        let tree = fullTree
        let instruct = makeDownloader(files: { _ in tree })
        let result = await instruct.validateCustomRepo("a/gemma-it", toolchain: toolchain)
        XCTAssertEqual(result, .valid(MLXRepoID("a/gemma-it")!, totalBytes: 11, isInstruct: true))

        let gone = makeDownloader(
            files: { _ in tree },
            config: { _ in throw HuggingFaceAPIClient.APIError.httpError(statusCode: 404) })
        let goneResult = await gone.validateCustomRepo("a/b", toolchain: nil)
        XCTAssertEqual(goneResult, .incompatible(MLXRepoID("a/b")!, .missingConfig))
    }

    func test_refreshPublishesRejectedModels() async throws {
        try writeCachedModel("a/gemma", type: "gemma4")
        try writeCachedModel("a/gemma-embed", type: "gemma4")
        let downloader = makeDownloader()
        await downloader.refreshCache(toolchain: toolchain)
        XCTAssertEqual(downloader.rejectedModels, [MLXRepoID("a/gemma-embed")!: .embeddingModel])
    }

    func test_downloadRunsTheToolchainPythonAndRefreshes() async throws {
        var calls: [(URL, [String], [String: String])] = []
        let downloader = makeDownloader(
            files: { _ in [HFRepoFile(path: "model.safetensors", size: 100)] },
            run: { [unowned self] executable, arguments, environment, _ in
                calls.append((executable, arguments, environment))
                if arguments.last == "a/b" { try self.writeCachedModel("a/b") }
                return MLXProcessResult(status: 0, stdout: "[\"gemma4\"]", stderrTail: [])
            }
        )
        downloader.startDownload(MLXRepoID("a/b")!, toolchain: toolchain)
        XCTAssertEqual(downloader.download?.isActive, true)
        await waitUntil { downloader.download == nil && downloader.cachedModels?.isEmpty == false }
        let download = try XCTUnwrap(calls.first { $0.1.last == "a/b" })
        XCTAssertEqual(download.0.path, "/mlx/python")
        XCTAssertEqual(download.1, ["-I", "-c", MLXToolchainRules.downloadScript, "a/b"])
        XCTAssertNil(download.2["HF_HUB_OFFLINE"])
        XCTAssertEqual(downloader.cachedModels?.map(\.repoID.value), ["a/b"])
    }

    func test_downloadFailureKeepsTheLastErrorLine() async {
        let downloader = makeDownloader(run: { _, arguments, _, _ in
            arguments.last == "a/b"
                ? MLXProcessResult(status: 1, stdout: "", stderrTail: ["Traceback", "RepositoryNotFoundError: a/b"])
                : MLXProcessResult(status: 0, stdout: "[]", stderrTail: [])
        })
        downloader.startDownload(MLXRepoID("a/b")!, toolchain: toolchain)
        await waitUntil { downloader.download?.isActive == false }
        XCTAssertEqual(downloader.download?.failure, "RepositoryNotFoundError: a/b")
    }

    func test_finishedDownloadOfUnsupportedArchitectureReportsIt() async {
        let downloader = makeDownloader(run: { [unowned self] _, arguments, _, _ in
            if arguments.last == "a/b" { try self.writeCachedModel("a/b", type: "mamba_x") }
            return MLXProcessResult(status: 0, stdout: "[\"gemma4\"]", stderrTail: [])
        })
        downloader.startDownload(MLXRepoID("a/b")!, toolchain: toolchain)
        await waitUntil { downloader.download?.isActive == false }
        XCTAssertEqual(downloader.download?.failure, "Downloaded, but it can't be used. Architecture “mamba_x” isn't supported by the installed mlx-lm.")
        XCTAssertEqual(downloader.cachedModels?.isEmpty, true)
    }

    func test_progressAndCancel() async throws {
        let downloader = makeDownloader(
            files: { _ in [HFRepoFile(path: "model.safetensors", size: 1000)] },
            run: { [unowned self] _, arguments, _, _ in
                guard arguments.last == "a/b" else { return MLXProcessResult(status: 0, stdout: "[]", stderrTail: []) }
                let blobs = self.cacheRoot.appendingPathComponent("models--a--b/blobs")
                try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
                try Data(count: 500).write(to: blobs.appendingPathComponent("x.incomplete"))
                try await Task.sleep(for: .seconds(60))
                return MLXProcessResult(status: 0, stdout: "", stderrTail: [])
            }
        )
        downloader.startDownload(MLXRepoID("a/b")!, toolchain: toolchain)
        await waitUntil { downloader.download?.fraction == 0.5 }
        downloader.startDownload(MLXRepoID("c/d")!, toolchain: toolchain)
        XCTAssertEqual(downloader.download?.repoID.value, "a/b", "one download at a time")
        downloader.cancelDownload()
        await waitUntil { downloader.download == nil }
    }

    /// Review focus 2.
    func test_deletingActiveModelRefreshesCacheWithoutIt() async throws {
        try writeCachedModel("a/b")
        let downloader = makeDownloader()
        await downloader.refreshCache(toolchain: toolchain)
        XCTAssertEqual(downloader.cachedModels?.count, 1)
        await downloader.delete(MLXRepoID("a/b")!, toolchain: toolchain)
        XCTAssertEqual(downloader.cachedModels, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("models--a--b").path))
    }

    /// Review focus 2 with a race: a scan that read the disk before the delete finishes after it.
    /// The first scan reads the model, then holds; the delete's own scan runs and publishes the
    /// list without it; releasing the stale scan must not bring the model back.
    func test_staleRefreshCannotResurrectADeletedModel() async throws {
        try writeCachedModel("a/b")
        let calls = CallCounter()
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let downloader = MLXModelDownloader(
            cacheRoot: cacheRoot, fileManager: .default,
            fetchRepoFiles: { _ in [] }, fetchIsGated: { _ in false },
            runProcess: { _, _, _, _ in MLXProcessResult(status: 0, stdout: "[\"gemma4\"]", stderrTail: []) },
            pollInterval: .milliseconds(20),
            scanCache: { root, types in
                let models = MLXCacheScanner.scanDetailed(cacheRoot: root, supportedModelTypes: types)
                if calls.next() == 1 {
                    enteredSignal.yield()
                    for await _ in release { break }
                }
                return models
            }
        )
        let stale = Task { await downloader.refreshCache(toolchain: nil) }
        for await _ in entered { break }

        // Nil toolchain skips the type probe, so the delete's scan does not wait on the held scan.
        await downloader.delete(MLXRepoID("a/b")!, toolchain: nil)
        XCTAssertEqual(downloader.cachedModels, [])

        releaseSignal.yield()
        await stale.value
        XCTAssertEqual(downloader.cachedModels, [], "the older scan saw the model before the delete and must not publish it")
    }

    /// Review focus 2: deleting the repo that is downloading must stop the download first, so the
    /// partial files cannot reappear once the folder is gone.
    func test_deletingTheActiveDownloadCancelsItFirst() async throws {
        let downloader = makeDownloader(
            files: { _ in [HFRepoFile(path: "model.safetensors", size: 1000)] },
            run: { [unowned self] _, arguments, _, _ in
                guard arguments.last == "a/b" else { return MLXProcessResult(status: 0, stdout: "[]", stderrTail: []) }
                let blobs = self.cacheRoot.appendingPathComponent("models--a--b/blobs")
                try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
                try Data(count: 500).write(to: blobs.appendingPathComponent("x.incomplete"))
                try await Task.sleep(for: .seconds(60))
                return MLXProcessResult(status: 0, stdout: "", stderrTail: [])
            }
        )
        downloader.startDownload(MLXRepoID("a/b")!, toolchain: toolchain)
        await waitUntil { downloader.download?.fraction == 0.5 }

        await downloader.delete(MLXRepoID("a/b")!, toolchain: nil)

        XCTAssertNil(downloader.download, "the delete waited for the download to stop")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("models--a--b").path))
        XCTAssertEqual(downloader.cachedModels, [])
    }
}

/// Counts calls from a `@Sendable` closure. The lock makes the count safe to bump from the detached scan.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Returns the 1-based number of this call.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
