import Combine
import Foundation
import Logging

/// File overview:
/// Owns everything about MLX model files:
/// - which usable models the Hugging Face cache holds (`cachedModels`);
/// - one download at a time, with byte progress and cancel;
/// - checking a custom repo id before downloading it;
/// - deleting a model.
/// Downloads run the toolchain's own Python with `huggingface_hub.snapshot_download`, so files
/// land exactly where `mlx_lm.server` looks and a cancelled download resumes next time. Owned by
/// `CotabbyAppEnvironment`; the Settings pane observes it.

/// The answer to "can Cotabby download this custom repo?", shown under the Settings text field.
/// A value type because the pane only renders it; it owns no state and no network access.
nonisolated enum MLXRepoValidation: Equatable, Sendable {
    case valid(MLXRepoID, totalBytes: Int64, isInstruct: Bool)
    case invalidID
    case notFoundOrPrivate(MLXRepoID)
    case gated(MLXRepoID)
    case incompatible(MLXRepoID, MLXModelCompatibility.Reason)
    case networkError(String)

    /// Nil for `.valid`; otherwise the sentence the pane shows under the field.
    var message: String? {
        switch self {
        case .valid: return nil
        case .invalidID: return "Enter a Hugging Face model id like mlx-community/gemma-4-e4b-5bit."
        case .notFoundOrPrivate(let id): return "\(id.value) was not found, or it is private."
        case .gated(let id): return "\(id.value) needs a Hugging Face login, which Cotabby does not support yet."
        case .incompatible(let id, let reason): return "\(id.value): \(reason.message)"
        case .networkError(let message): return "Could not reach Hugging Face: \(message)"
        }
    }
}

/// The download and cache manager behind the MLX model list. It is `@MainActor` because the
/// Settings pane observes its published state; the heavy work (directory scans, the Python
/// download itself) runs off the main actor and only the resulting values are published back.
/// Its collaborators are injected closures, so tests replace the network and the process with fakes.
@MainActor
final class MLXModelDownloader: ObservableObject {
    typealias RepoFilesFetch = (String) async throws -> [HFRepoFile]
    typealias GatedFetch = (String) async throws -> Bool
    /// Downloads one small file (`config.json`) of a remote repo: repo id, then file path.
    typealias ConfigFetch = (String) async throws -> Data
    typealias RunProcess = (URL, [String], [String: String], Duration) async throws -> MLXProcessResult
    /// The cache scan, injectable so a test can hold one scan after it has read the disk.
    typealias CacheScan = @Sendable (URL, Set<String>?) async -> MLXCacheScanResult

    /// Nil until the first scan finishes, so the server wiring waits instead of reporting the
    /// selected model as missing during launch.
    @Published private(set) var cachedModels: [MLXCachedModel]?
    /// Complete downloads the compatibility rule turned away, with the reason. Published together
    /// with `cachedModels` so the UI and the server wiring never see one without the other.
    @Published private(set) var rejectedModels: [MLXRepoID: MLXModelCompatibility.Reason] = [:]
    @Published private(set) var download: MLXDownloadState?

    private let cacheRoot: URL
    private let fileManager: FileManager
    private let fetchRepoFiles: RepoFilesFetch
    private let fetchIsGated: GatedFetch
    private let fetchConfig: ConfigFetch
    private let runProcess: RunProcess
    private let pollInterval: Duration
    private let scanCache: CacheScan
    /// The architectures the installed mlx-lm supports, cached per Python (asked once, ~1 s).
    private var supportedTypes: (python: URL, types: Set<String>?)?
    private var downloadTask: Task<Void, Never>?
    /// Bumped by every `refreshCache`. Scans run off the main actor, so two can overlap; a scan
    /// that started before a delete could finish last and publish the deleted model again. Only
    /// the newest refresh may publish.
    private var refreshGeneration: UInt64 = 0

    init(
        cacheRoot: URL,
        fileManager: FileManager = .default,
        fetchRepoFiles: @escaping RepoFilesFetch = { try await HuggingFaceAPIClient.fetchRepoFiles(repoId: $0) },
        fetchIsGated: @escaping GatedFetch = { try await HuggingFaceAPIClient.isGated(repoId: $0) },
        fetchConfig: @escaping ConfigFetch = {
            try await HuggingFaceAPIClient.fetchFileData(repoId: $0, path: "config.json")
        },
        runProcess: @escaping RunProcess = { executable, arguments, environment, timeout in
            try await MLXProcessRunner.run(
                executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        },
        pollInterval: Duration = .milliseconds(500),
        scanCache: @escaping CacheScan = { root, types in
            MLXCacheScanner.scanDetailed(cacheRoot: root, supportedModelTypes: types)
        }
    ) {
        self.cacheRoot = cacheRoot
        self.fileManager = fileManager
        self.fetchRepoFiles = fetchRepoFiles
        self.fetchIsGated = fetchIsGated
        self.fetchConfig = fetchConfig
        self.runProcess = runProcess
        self.pollInterval = pollInterval
        self.scanCache = scanCache
    }

    static func live() -> MLXModelDownloader {
        MLXModelDownloader(cacheRoot: MLXCacheScanner.cacheRoot(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        ))
    }

    func refreshCache(toolchain: MLXToolchain?) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let types = await supportedModelTypes(for: toolchain)
        let root = cacheRoot
        let scan = scanCache
        let result = await Task.detached(priority: .utility) {
            await scan(root, types)
        }.value
        // A newer refresh started while this one was suspended, so its answer is the current one.
        // Publishing this older scan could bring back a model that was just deleted.
        guard generation == refreshGeneration else { return }
        cachedModels = result.models
        rejectedModels = result.rejected
    }

    /// Checks a custom repo before any download, with the same `MLXModelCompatibility` rule the
    /// cache scan uses, so "accepted here" and "listed after download" cannot disagree. The repo's
    /// `config.json` (a few KB) is fetched for the architecture and head checks; a 404 there means
    /// the repo has no config at all.
    func validateCustomRepo(_ raw: String, toolchain: MLXToolchain?) async -> MLXRepoValidation {
        guard let repoID = MLXRepoID(raw) else { return .invalidID }
        do {
            let files = try await fetchRepoFiles(repoID.value)
            if try await fetchIsGated(repoID.value) { return .gated(repoID) }
            var config: [String: Any]?
            if files.contains(where: { $0.path == "config.json" }) {
                do {
                    let data = try await fetchConfig(repoID.value)
                    config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                } catch HuggingFaceAPIClient.APIError.httpError(404) {
                    return .incompatible(repoID, .missingConfig)
                }
            }
            let types = await supportedModelTypes(for: toolchain)
            switch MLXModelCompatibility.verdict(
                repoName: repoID.name, fileNames: files.map(\.path), config: config, supportedModelTypes: types
            ) {
            case .incompatible(let reason):
                return .incompatible(repoID, reason)
            case .compatible(_, let isInstruct):
                return .valid(repoID, totalBytes: files.reduce(Int64(0)) { $0 + $1.size }, isInstruct: isInstruct)
            }
        } catch HuggingFaceAPIClient.APIError.httpError(let code) where [401, 403, 404].contains(code) {
            return .notFoundOrPrivate(repoID)
        } catch {
            return .networkError(error.localizedDescription)
        }
    }

    /// Starts one download; ignored while another runs.
    func startDownload(_ repoID: MLXRepoID, toolchain: MLXToolchain) {
        guard downloadTask == nil else { return }
        download = MLXDownloadState(repoID: repoID, fraction: nil, failure: nil, isActive: true)
        CotabbyLogger.runtime.info("MLX model download started", metadata: ["model": .string(repoID.value)])
        downloadTask = Task { [weak self] in
            await self?.runDownload(repoID, toolchain: toolchain)
        }
    }

    /// Terminates the download process. huggingface_hub resumes the partial files next time.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Removes the repo from the shared cache, then rescans (the server wiring reacts if it was
    /// the selected model).
    func delete(_ repoID: MLXRepoID, toolchain: MLXToolchain?) async {
        // A download still writing into this folder would bring the model back, so stop it and wait
        // until it has really finished before removing anything.
        if download?.repoID == repoID, download?.isActive == true {
            let task = downloadTask
            task?.cancel()
            await task?.value
        }
        let folder = cacheRoot.appendingPathComponent(repoID.cacheFolderName, isDirectory: true)
        let manager = fileManager
        // Model folders are several GB; removing them on the main actor would stall the UI.
        let failure: String? = await Task.detached(priority: .utility) { () -> String? in
            guard manager.fileExists(atPath: folder.path) else { return nil }
            do {
                try manager.removeItem(at: folder)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        if let failure {
            CotabbyLogger.runtime.error(
                "Could not delete MLX model",
                metadata: ["model": .string(repoID.value), "error": .string(failure)])
        } else {
            CotabbyLogger.runtime.info("Deleted MLX model", metadata: ["model": .string(repoID.value)])
        }
        await refreshCache(toolchain: toolchain)
    }

    // MARK: - Private

    private func runDownload(_ repoID: MLXRepoID, toolchain: MLXToolchain) async {
        let total = (try? await fetchRepoFiles(repoID.value))?.reduce(Int64(0)) { $0 + $1.size } ?? 0
        let root = cacheRoot
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                let bytes = await Task.detached(priority: .utility) {
                    MLXCacheScanner.downloadedBytes(repo: repoID, cacheRoot: root)
                }.value
                guard let self, self.download?.repoID == repoID, self.download?.isActive == true else { return }
                self.download?.fraction = MLXCacheScanner.progress(downloadedBytes: bytes, totalBytes: total)
                try? await Task.sleep(for: self.pollInterval)
            }
        }

        let outcome: Result<MLXProcessResult, Error>
        do {
            outcome = .success(try await runProcess(
                toolchain.pythonExecutable,
                ["-I", "-c", MLXToolchainRules.downloadScript, repoID.value],
                MLXToolchainRules.downloadEnvironment(base: ProcessInfo.processInfo.environment),
                .seconds(6 * 60 * 60)
            ))
        } catch {
            outcome = .failure(error)
        }
        poller.cancel()

        switch outcome {
        case .success(let result) where result.status == 0:
            // Cleared after the rescan below, once we know the model is actually usable.
            CotabbyLogger.runtime.info("MLX model downloaded", metadata: ["model": .string(repoID.value)])
        case .success(let result):
            download = MLXDownloadState(
                repoID: repoID, fraction: download?.fraction,
                failure: result.stderrTail.last ?? "The download failed.", isActive: false)
        case .failure(let error) where error is CancellationError:
            download = nil
        case .failure(let error):
            download = MLXDownloadState(
                repoID: repoID, fraction: download?.fraction, failure: error.localizedDescription, isActive: false)
        }
        downloadTask = nil
        await refreshCache(toolchain: toolchain)
        // A finished download that the rescan does not list is one the installed mlx-lm cannot run
        // (its architecture is unsupported); clearing the card silently would look like a no-op.
        if case .success(let result) = outcome, result.status == 0, download?.repoID == repoID {
            if cachedModels?.contains(where: { $0.repoID == repoID }) == true {
                download = nil
            } else {
                // No rejection means the snapshot is missing files, i.e. the download is incomplete.
                let failure = rejectedModels[repoID].map { "Downloaded, but it can't be used. \($0.message)" }
                    ?? "The download did not complete. Try again."
                download = MLXDownloadState(
                    repoID: repoID, fraction: 1,
                    failure: failure,
                    isActive: false)
            }
        }
    }

    /// The architectures the installed mlx-lm supports, nil without a toolchain or when the probe
    /// failed. Cached per Python so the ~1 s probe runs once.
    private func supportedModelTypes(for toolchain: MLXToolchain?) async -> Set<String>? {
        guard let toolchain else { return nil }
        if let cached = supportedTypes, cached.python == toolchain.pythonExecutable { return cached.types }
        let types = await loadSupportedTypes(python: toolchain.pythonExecutable)
        // Cache only a real answer: a probe that failed or was cancelled must be retried
        // next time, not remembered as "unknown" (which turns the type filter off).
        if types != nil { supportedTypes = (toolchain.pythonExecutable, types) }
        return types
    }

    private func loadSupportedTypes(python: URL) async -> Set<String>? {
        guard let result = try? await runProcess(
            python,
            ["-I", "-c", MLXToolchainRules.supportedModelTypesScript],
            MLXToolchainRules.sanitizedEnvironment(ProcessInfo.processInfo.environment),
            .seconds(30)
        ), result.status == 0,
        let names = try? JSONDecoder().decode([String].self, from: Data(result.stdout.utf8))
        else { return nil }
        return Set(names)
    }
}
