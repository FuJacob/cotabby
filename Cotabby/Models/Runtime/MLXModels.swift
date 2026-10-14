import Foundation

/// File overview:
/// Shared values for the MLX engine: what this Mac can run, where Cotabby keeps its MLX install,
/// which models it offers, and the states the toolchain, server and downloads publish. Settings,
/// the router and the MLX services all read these, so they live in `Models/` rather than inside
/// any one service.

/// Whether this build can run MLX. MLX needs Apple Silicon. A compile-time check is enough: an
/// x86_64 Cotabby (Intel, or Rosetta) cannot rely on an arm64 Python stack being usable either.
nonisolated enum MLXHardware {
    static let isAppleSilicon: Bool = {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }()
}

/// The sampling fields `mlx_lm.server` accepts beyond OpenAI's basics. The MLX engine fills them
/// from the same request values the llama runtime samples with, so both local engines condition
/// alike. The client encodes them only when present, so hosted endpoints never see keys they
/// might reject.
nonisolated struct MLXCompletionOptions: Equatable, Sendable {
    let topK: Int
    let minP: Double
    let repetitionPenalty: Double
    /// Nil lets the server pick; Cotabby passes the request's seed so a replay is reproducible.
    let seed: Int?
    /// Server-side stop strings. `["\n"]` for single-line fields stands in for the llama runtime's
    /// newline-token masking; empty for multi-line fields.
    let stop: [String]
}

/// Where Cotabby keeps its own MLX install and server bookkeeping. The folder sits beside the
/// llama runtime folder under the bundle's own Application Support name, so the Dev and release
/// apps never share an install or a pid file.
nonisolated struct MLXPaths: Equatable, Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/<CFBundleName>/MLX`. The folder is keyed by `CFBundleName`
    /// so the Dev and release apps (different names) get separate installs and cannot delete or
    /// overwrite each other's toolchain.
    static func standard(bundle: Bundle = .main) -> MLXPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Cotabby"
        return MLXPaths(root: support.appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("MLX", isDirectory: true))
    }

    var uvDirectory: URL { root.appendingPathComponent("uv", isDirectory: true) }
    /// The archive unpacks into a folder named after the platform triple.
    var uvExecutable: URL { uvDirectory.appendingPathComponent("uv-aarch64-apple-darwin/uv") }
    var toolsDirectory: URL { root.appendingPathComponent("tools", isDirectory: true) }
    var binDirectory: URL { root.appendingPathComponent("bin", isDirectory: true) }
    var pythonDirectory: URL { root.appendingPathComponent("python", isDirectory: true) }
    var cacheDirectory: URL { root.appendingPathComponent("cache", isDirectory: true) }
    var ownServerExecutable: URL { binDirectory.appendingPathComponent("mlx_lm.server") }
    var serverPIDFile: URL { root.appendingPathComponent("server.pid") }
}

/// A validated Hugging Face model repo id ("owner/name"). It reaches a command line
/// (`--model`, `snapshot_download`) and a cache folder name, so only Hugging Face's own name
/// alphabet is accepted, never path syntax. A pasted model-page URL is reduced to its id.
nonisolated struct MLXRepoID: Equatable, Hashable, Sendable, CustomStringConvertible {
    let owner: String
    let name: String

    var value: String { "\(owner)/\(name)" }
    var description: String { value }
    /// The folder `huggingface_hub` caches this repo under.
    var cacheFolderName: String { "models--\(owner)--\(name)" }

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let host = url.host {
            guard host == "huggingface.co" || host == "www.huggingface.co" else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            text = "\(parts[0])/\(parts[1])"
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Self.isValidComponent(parts[0]), Self.isValidComponent(parts[1]) else {
            return nil
        }
        owner = parts[0]
        name = parts[1]
    }

    init?(cacheFolderName: String) {
        guard cacheFolderName.hasPrefix("models--") else { return nil }
        let parts = cacheFolderName.dropFirst("models--".count).components(separatedBy: "--")
        guard parts.count == 2 else { return nil }
        self.init("\(parts[0])/\(parts[1])")
    }

    /// Hugging Face allows letters, digits, `-`, `_` and `.`, forbids `--` and `..`, and names
    /// cannot start with `-` or `.`; at most 96 characters.
    private static func isValidComponent(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 96,
              let first = text.unicodeScalars.first,
              first != "-", first != ".",
              !text.contains("--"), !text.contains("..")
        else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return text.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }
}

/// One model Cotabby recommends, shown even before it is downloaded.
nonisolated struct MLXCatalogEntry: Equatable, Sendable, Identifiable {
    let repoID: MLXRepoID
    let displayName: String
    let approximateBytes: Int64
    let note: String
    let isRecommended: Bool
    var id: String { repoID.value }
}

/// A usable MLX model found in the Hugging Face cache (produced by `MLXCacheScanner`).
nonisolated struct MLXCachedModel: Equatable, Sendable, Identifiable {
    let repoID: MLXRepoID
    let snapshotURL: URL
    let sizeBytes: Int64
    let modelType: String
    let isInstruct: Bool
    var id: String { repoID.value }
}

/// One row of the Settings model list: a curated or cached model, downloaded or not.
nonisolated struct MLXModelOption: Equatable, Sendable, Identifiable {
    let repoID: MLXRepoID
    let displayName: String
    let sizeBytes: Int64
    let isDownloaded: Bool
    let isRecommended: Bool
    let note: String?
    var id: String { repoID.value }
}

/// The curated list and the rule that merges it with what the cache holds. A pure namespace: the
/// downloader publishes the cached models and the pane asks this type for the rows to show.
nonisolated enum MLXModelCatalog {
    static let instructNote = "Instruct model: base models complete text better."

    static let curated: [MLXCatalogEntry] = [
        MLXCatalogEntry(
            repoID: MLXRepoID("mlx-community/gemma-4-e4b-5bit")!,
            displayName: "Gemma 4 E4B (5-bit)",
            approximateBytes: 6_100_000_000,
            note: "Recommended. Same model family as the Open Source default.",
            isRecommended: true
        ),
        MLXCatalogEntry(
            repoID: MLXRepoID("mlx-community/gemma-4-e2b-6bit")!,
            displayName: "Gemma 4 E2B (6-bit)",
            approximateBytes: 4_700_000_000,
            note: "Smaller and faster.",
            isRecommended: false
        )
    ]

    /// Curated entries first, in catalog order, then every other cached model sorted by id.
    static func options(cached: [MLXCachedModel], curated: [MLXCatalogEntry] = curated) -> [MLXModelOption] {
        let cachedByID = Dictionary(cached.map { ($0.repoID, $0) }, uniquingKeysWith: { first, _ in first })
        let curatedIDs = Set(curated.map(\.repoID))
        let curatedRows = curated.map { entry in
            let hit = cachedByID[entry.repoID]
            return MLXModelOption(
                repoID: entry.repoID,
                displayName: entry.displayName,
                sizeBytes: hit?.sizeBytes ?? entry.approximateBytes,
                isDownloaded: hit != nil,
                isRecommended: entry.isRecommended,
                note: entry.note
            )
        }
        let otherRows = cached
            .filter { !curatedIDs.contains($0.repoID) }
            .sorted { $0.repoID.value.localizedCaseInsensitiveCompare($1.repoID.value) == .orderedAscending }
            .map { model in
                MLXModelOption(
                    repoID: model.repoID,
                    displayName: model.repoID.value,
                    sizeBytes: model.sizeBytes,
                    isDownloaded: true,
                    isRecommended: false,
                    note: model.isInstruct ? instructNote : nil
                )
            }
        return curatedRows + otherRows
    }

    /// The download that no row in `options` shows: a custom model started from the "Other MLX
    /// Model" field is not in the catalog until it is cached, so its progress, Cancel and failure
    /// need a place of their own. Nil when the download (if any) already has a row.
    static func downloadWithoutRow(_ download: MLXDownloadState?, options: [MLXModelOption]) -> MLXDownloadState? {
        guard let download, !options.contains(where: { $0.repoID == download.repoID }) else { return nil }
        return download
    }

    /// The model to select when the user picks MLX without having chosen one: a downloaded
    /// curated model first, then any downloaded model, else nil (the pane then offers downloads).
    static func defaultSelection(cached: [MLXCachedModel]) -> MLXRepoID? {
        let cachedIDs = Set(cached.map(\.repoID))
        if let curatedHit = curated.first(where: { cachedIDs.contains($0.repoID) }) {
            return curatedHit.repoID
        }
        return cached.first?.repoID
    }
}

/// A usable mlx-lm install: the server script and the Python that runs it.
nonisolated struct MLXToolchain: Equatable, Sendable {
    let serverExecutable: URL
    let pythonExecutable: URL
    let version: String
    /// True for Cotabby's own install under `MLXPaths`, which Remove may delete.
    let isCotabbyInstall: Bool
}

/// The steps of Cotabby's own MLX install, in order. The installer reports the current one so the
/// Settings pane can say what is happening during a multi-minute wait; the provisioner publishes it
/// inside `MLXToolchainState.installing`.
nonisolated enum MLXInstallPhase: String, Equatable, Sendable {
    case downloadingUV
    case verifyingUV
    case installingMLX

    var label: String {
        switch self {
        case .downloadingUV: return "Downloading the installer…"
        case .verifyingUV: return "Verifying the installer…"
        case .installingMLX: return "Installing MLX (a few minutes the first time)…"
        }
    }
}

/// What the Settings pane and the server wiring know about mlx-lm on this Mac.
nonisolated enum MLXToolchainState: Equatable, Sendable {
    case checking
    case notInstalled
    case tooOld(version: String, path: String)
    case installing(MLXInstallPhase)
    case ready(MLXToolchain)
    case failed(reason: String, logTail: [String])

    var toolchain: MLXToolchain? {
        if case .ready(let toolchain) = self { return toolchain }
        return nil
    }
}

/// Why the MLX server is not running although MLX is the selected engine.
nonisolated enum MLXUnavailableReason: Equatable, Sendable {
    case unsupportedHardware
    case notInstalled
    case noModel
    case modelNotDownloaded(MLXRepoID)
    /// The model is downloaded but `MLXModelCompatibility` rejected it; the string is the reason.
    case modelIncompatible(MLXRepoID, String)

    var message: String {
        switch self {
        case .unsupportedHardware: return "MLX needs a Mac with Apple Silicon."
        case .notInstalled: return "Install MLX in Settings → Engine & Model."
        case .noModel: return "Choose an MLX model in Settings → Engine & Model."
        case .modelNotDownloaded(let id): return "Download \(id.value) in Settings → Engine & Model."
        case .modelIncompatible(let id, let reason): return "\(id.value) can't run on MLX: \(reason)"
        }
    }
}

/// The MLX server's lifecycle as the router, Settings and the menu bar see it.
nonisolated enum MLXServerState: Equatable, Sendable {
    case idle
    case unavailable(MLXUnavailableReason)
    case starting(modelID: String)
    case ready(port: Int, modelID: String)
    case failed(reason: String, logTail: [String])
    case stopping

    var summary: String {
        switch self {
        case .idle: return "Not running"
        case .unavailable(let reason): return reason.message
        case .starting(let modelID): return "Loading \(modelID)…"
        case .ready(_, let modelID): return "Running \(modelID)"
        case .failed(let reason, _): return reason
        case .stopping: return "Stopping…"
        }
    }

    /// Text for the Settings attention dot and callout. Nil while the server is running, loading,
    /// stopping, or simply not selected: none of those need the user to act.
    var problem: String? {
        switch self {
        case .unavailable(let reason): return reason.message
        case .failed(let reason, _): return reason
        case .idle, .starting, .ready, .stopping: return nil
        }
    }

    /// The `.unavailable` message a suggestion request gets while the server is not ready.
    var notReadyMessage: String {
        switch self {
        case .starting(let modelID): return "MLX is loading \(modelID)…"
        case .unavailable(let reason): return reason.message
        case .failed(let reason, _): return "MLX stopped: \(reason)"
        case .idle, .stopping: return "MLX is not running."
        case .ready: return "MLX is ready."
        }
    }
}

/// One model download as the pane shows it.
nonisolated struct MLXDownloadState: Equatable, Sendable {
    let repoID: MLXRepoID
    /// 0...1 once the total size is known; nil before that.
    var fraction: Double?
    var failure: String?
    var isActive: Bool
}

/// One running `mlx_lm.server` as `MLXServerManager` sees it. A protocol so tests drive the
/// manager with a fake process instead of Python.
protocol MLXRunningProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    /// SIGTERM: ask the server to exit.
    func terminate()
    /// SIGKILL: used only after the grace period.
    func forceKill()
    /// The last lines the server wrote to stderr, for the failure message.
    func stderrTail() -> [String]
}

/// Starts the server process. `onExit` is delivered on the main actor with the exit status.
protocol MLXProcessLaunching {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any MLXRunningProcess
}

/// Waits until a launched server answers `/v1/models` and has finished a warm-up completion.
protocol MLXReadinessProbing {
    func waitUntilReady(port: Int, modelID: String, timeout: Duration) async throws
}
