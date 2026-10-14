import Foundation

/// File overview:
/// Reads the Hugging Face cache the way huggingface_hub lays it out and decides which cached repos
/// are models `mlx_lm.server` can run for autocomplete. Pure apart from reading the folder it is
/// given, so tests build fixture trees in a temp directory. Lives in `Support/` because it is a
/// rule ("what counts as a usable MLX model"), not a service with state.
///
/// Cache layout: `<root>/models--<owner>--<name>/{blobs/<sha>[.incomplete], refs/main,
/// snapshots/<revision>/<file> -> ../../blobs/<sha>}`.
nonisolated enum MLXCacheScanner {
    /// Same precedence as huggingface_hub. GUI apps rarely inherit these variables (launchd does
    /// not read shell profiles), so the default path is the common case.
    static func cacheRoot(environment: [String: String], home: URL) -> URL {
        if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
            return URL(fileURLWithPath: hubCache, isDirectory: true)
        }
        if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome, isDirectory: true).appendingPathComponent("hub", isDirectory: true)
        }
        return home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// Every usable model, sorted by repo id. `supportedModelTypes` is nil when mlx-lm is not
    /// installed yet; the type filter is then skipped (nothing can run anyway, and hiding the
    /// user's models would read as "your download vanished").
    static func scan(
        cacheRoot: URL,
        supportedModelTypes: Set<String>?,
        fileManager: FileManager = .default
    ) -> [MLXCachedModel] {
        scanDetailed(cacheRoot: cacheRoot, supportedModelTypes: supportedModelTypes, fileManager: fileManager).models
    }

    /// Like `scan`, but also reports the repos that have a complete snapshot and still fail
    /// `MLXModelCompatibility`, so the UI can say why a downloaded model is not offered. A repo with
    /// no `refs/main` snapshot, or whose snapshot is incomplete (`isComplete`), is neither listed
    /// nor rejected: it is simply not downloaded.
    static func scanDetailed(
        cacheRoot: URL,
        supportedModelTypes: Set<String>?,
        fileManager: FileManager = .default
    ) -> MLXCacheScanResult {
        guard let folders = try? fileManager.contentsOfDirectory(atPath: cacheRoot.path) else {
            return MLXCacheScanResult(models: [], rejected: [:])
        }
        var models: [MLXCachedModel] = []
        var rejected: [MLXRepoID: MLXModelCompatibility.Reason] = [:]
        for folder in folders {
            guard let repoID = MLXRepoID(cacheFolderName: folder) else { continue }
            let repoURL = cacheRoot.appendingPathComponent(folder, isDirectory: true)
            guard let snapshot = currentSnapshot(repoURL, fileManager: fileManager),
                  let files = try? fileManager.contentsOfDirectory(atPath: snapshot.path),
                  isComplete(snapshot, files: files, fileManager: fileManager)
            else { continue }
            let config = readConfig(snapshot.appendingPathComponent("config.json"))
            switch MLXModelCompatibility.verdict(
                repoName: repoID.name, fileNames: files, config: config, supportedModelTypes: supportedModelTypes
            ) {
            case .compatible(let modelType, let isInstruct):
                models.append(MLXCachedModel(
                    repoID: repoID,
                    snapshotURL: snapshot,
                    sizeBytes: snapshotBytes(snapshot, files: files, fileManager: fileManager),
                    modelType: modelType,
                    isInstruct: isInstruct
                ))
            case .incompatible(.missingConfig), .incompatible(.missingWeights), .incompatible(.missingTokenizer):
                // A snapshot with files missing is an interrupted download or another tool's
                // placeholder: "not downloaded", not "incompatible". Telling the user the model
                // can't run would hide the real fix, which is to download it.
                continue
            case .incompatible(let reason):
                rejected[repoID] = reason
            }
        }
        models.sort { $0.repoID.value.localizedCaseInsensitiveCompare($1.repoID.value) == .orderedAscending }
        return MLXCacheScanResult(models: models, rejected: rejected)
    }

    /// Forwarded so existing callers keep working; the rule lives in `MLXModelCompatibility`.
    static func isInstructName(_ name: String) -> Bool {
        MLXModelCompatibility.isInstructName(name)
    }

    /// Bytes of a repo's blobs, finished and partial, for download progress.
    static func downloadedBytes(repo: MLXRepoID, cacheRoot: URL, fileManager: FileManager = .default) -> Int64 {
        let blobs = cacheRoot.appendingPathComponent("\(repo.cacheFolderName)/blobs", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: blobs.path) else { return 0 }
        return names.reduce(Int64(0)) { sum, name in
            let size = (try? fileManager.attributesOfItem(atPath: blobs.appendingPathComponent(name).path)[.size]) as? NSNumber
            return sum + (size?.int64Value ?? 0)
        }
    }

    static func progress(downloadedBytes: Int64, totalBytes: Int64) -> Double? {
        guard totalBytes > 0 else { return nil }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }

    // MARK: - Private

    /// Whether the snapshot holds everything `mlx_lm` will load. huggingface_hub links a file into
    /// the snapshot only after its blob is complete, so a download in progress elsewhere in the repo
    /// (an `.incomplete` blob for another revision or an unused file) does not matter here. Two
    /// things do: every entry must reach a readable file (a deleted blob leaves a dangling link),
    /// and a sharded model's `model.safetensors.index.json` must find every shard it names, because
    /// a download stopped between files leaves some shards, the config and the tokenizer in place.
    static func isComplete(_ snapshot: URL, files: [String], fileManager: FileManager = .default) -> Bool {
        for name in files {
            let target = snapshot.appendingPathComponent(name).resolvingSymlinksInPath()
            guard fileManager.isReadableFile(atPath: target.path) else { return false }
        }
        let indexName = "model.safetensors.index.json"
        guard files.contains(indexName) else { return true }
        guard let data = try? Data(contentsOf: snapshot.appendingPathComponent(indexName)),
              let index = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let weightMap = index["weight_map"] as? [String: String]
        else { return false }
        return Set(weightMap.values).isSubset(of: Set(files))
    }

    /// The revision `refs/main` names. `mlx_lm.server` runs offline with the repo id, which
    /// huggingface_hub resolves through `refs/main`; a snapshot cached only by commit could not be
    /// loaded, so it does not count as downloaded.
    private static func currentSnapshot(_ repo: URL, fileManager: FileManager) -> URL? {
        guard let revision = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !revision.isEmpty
        else { return nil }
        let url = repo.appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private static func readConfig(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Snapshot files are symlinks into `blobs/`; sizes are read from the link targets.
    private static func snapshotBytes(_ snapshot: URL, files: [String], fileManager: FileManager) -> Int64 {
        files.reduce(Int64(0)) { sum, name in
            let target = snapshot.appendingPathComponent(name).resolvingSymlinksInPath()
            let size = (try? fileManager.attributesOfItem(atPath: target.path)[.size]) as? NSNumber
            return sum + (size?.int64Value ?? 0)
        }
    }
}

/// The outcome of one cache scan: the models Cotabby can use and why the other complete downloads
/// cannot be used. A plain value produced by `MLXCacheScanner` and published by
/// `MLXModelDownloader`; it owns nothing.
nonisolated struct MLXCacheScanResult: Equatable, Sendable {
    let models: [MLXCachedModel]
    let rejected: [MLXRepoID: MLXModelCompatibility.Reason]
}
