import Foundation

/// File overview:
/// Defines the MLX-side local runtime values: discovered model snapshots, bootstrap diagnostics,
/// runtime configuration, generation options, and user-visible errors.
///
/// This file exists as a separate boundary from `LlamaRuntimeModels` because MLX models are
/// directory snapshots (weights + tokenizer + config), while llama.cpp models are single GGUF
/// files. Keeping the shapes separate prevents the UI from pretending those storage formats are
/// interchangeable just because both are local and private.

/// One discovered MLX model snapshot that can be selected for autocomplete generation.
///
/// A snapshot is a directory, usually from Hugging Face, containing at least `config.json`, tokenizer
/// files, and one or more weight shards. The directory URL is the durable load path; `id` is the
/// stable picker identity persisted across launches.
struct MlxRuntimeModelOption: Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let url: URL

    var displayName: String {
        MlxRuntimeModelCatalog.displayName(for: id)
    }

    var actualModelName: String {
        id
    }
}

/// Downloadable MLX model metadata used by Settings and onboarding once MLX catalogs are exposed.
///
/// Unlike `DownloadableRuntimeModel`, this describes a snapshot repository rather than one direct
/// file URL. The first implementation can import local directories; the same value type is ready for
/// a later snapshot downloader that fetches all required files into `MlxRuntime/`.
struct DownloadableMlxRuntimeModel: Equatable, Hashable, Sendable, Identifiable {
    let repositoryID: String
    let displayName: String
    let approximateSizeInGigabytes: Double
    let revision: String?

    var id: String { repositoryID }
    var approximateSizeLabel: String { String(format: "~%.1f GB", approximateSizeInGigabytes) }
}

enum MlxRuntimeModelCatalog {
    static func displayName(for modelID: String) -> String {
        switch modelID {
        case "mlx-community/Qwen3-4B-4bit":
            return "Qwen3 4B MLX"
        case "mlx-community/gemma-3-1b-it-qat-4bit":
            return "Gemma 3 1B MLX"
        default:
            return modelID.components(separatedBy: "/").last ?? modelID
        }
    }

    /// Conservative starter catalog. These are not automatically downloaded yet; they establish the
    /// product-facing IDs and size expectations for the directory-aware downloader work.
    static let downloadableModels: [DownloadableMlxRuntimeModel] = [
        DownloadableMlxRuntimeModel(
            repositoryID: "mlx-community/gemma-3-1b-it-qat-4bit",
            displayName: displayName(for: "mlx-community/gemma-3-1b-it-qat-4bit"),
            approximateSizeInGigabytes: 0.8,
            revision: nil
        ),
        DownloadableMlxRuntimeModel(
            repositoryID: "mlx-community/Qwen3-4B-4bit",
            displayName: displayName(for: "mlx-community/Qwen3-4B-4bit"),
            approximateSizeInGigabytes: 2.5,
            revision: nil
        )
    ]
}

/// Startup configuration for the MLX runtime.
///
/// `runtimeDirectoryPath` is optional so tests and advanced local setups can point at a temporary
/// model root. The app default is the user-writable Application Support directory.
struct MlxRuntimeConfiguration: Equatable, Sendable {
    let runtimeDirectoryPath: String?
    let preferredModelIDs: [String]
    let maxKVSize: Int?
    let kvBits: Int?
    let prefillStepSize: Int

    static let `default` = MlxRuntimeConfiguration(
        runtimeDirectoryPath: nil,
        preferredModelIDs: [
            "mlx-community/gemma-3-1b-it-qat-4bit",
            "mlx-community/Qwen3-4B-4bit"
        ],
        maxKVSize: nil,
        kvBits: nil,
        prefillStepSize: 512
    )
}

/// Concrete local MLX model selected during bootstrap.
struct ResolvedMlxRuntime: Equatable, Sendable {
    let runtimeDirectoryURL: URL
    let modelDirectoryURL: URL
    let modelID: String
    let modelDisplayName: String
}

/// Operator-facing MLX diagnostics displayed in Settings and logs.
struct MlxRuntimeDiagnostics: Equatable, Sendable {
    var runtimeDirectoryPath: String?
    var modelDirectoryPath: String?
    var backendName: String?
    var contextWindowTokens: Int?
    var maxKVSize: Int?
    var kvBits: Int?
    var prefillStepSize: Int?
    var lastLoadStatus: String?
    var lastError: String?
    var lastCacheStatus: String?
}

/// Immutable runtime metadata captured after the MLX model has been prepared.
struct PreparedMlxRuntime: Sendable {
    let resolvedRuntime: ResolvedMlxRuntime
    let backendName: String
    let contextWindowTokens: Int?
    let maxKVSize: Int?
    let kvBits: Int?
    let prefillStepSize: Int
}

/// Runtime failures surfaced before or during MLX generation.
enum MlxRuntimeError: LocalizedError {
    case unavailable(String)
    case cancelled
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .generationFailed(let message):
            return message
        case .cancelled:
            return "MLX runtime work was cancelled."
        }
    }
}

/// Small helper for the MLX cache-reuse state machine.
///
/// This pure type is deliberately independent from `MLXLMCommon.KVCache` so its reuse math can be
/// tested without loading a model. Runtime code uses the decision to decide whether to trim and
/// reuse its backend cache or throw it away and prefill fresh.
struct MlxPromptCacheDecision: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case fresh(reason: String)
        case reuse(commonPrefixTokens: Int)
    }

    let action: Action
}

enum MlxPromptCachePlanner {
    static func decision(
        cachedTokens: [Int],
        newTokens: [Int],
        cachedFingerprint: String?,
        newFingerprint: String,
        cacheIsTrimmable: Bool
    ) -> MlxPromptCacheDecision {
        guard cacheIsTrimmable else {
            return MlxPromptCacheDecision(action: .fresh(reason: "cache_not_trimmable"))
        }
        guard cachedFingerprint == newFingerprint else {
            return MlxPromptCacheDecision(action: .fresh(reason: "sampling_changed"))
        }
        guard !cachedTokens.isEmpty, !newTokens.isEmpty else {
            return MlxPromptCacheDecision(action: .fresh(reason: "empty_prompt"))
        }

        let commonPrefix = commonPrefixCount(cachedTokens, newTokens)
        guard commonPrefix > 0 else {
            return MlxPromptCacheDecision(action: .fresh(reason: "no_shared_prefix"))
        }

        // Keep at most prompt-prefix state. The sampled continuation is trimmed after every
        // generation, so reusing the full prompt is valid; callers still need to prefill any suffix
        // beyond this prefix before sampling.
        return MlxPromptCacheDecision(action: .reuse(commonPrefixTokens: min(commonPrefix, newTokens.count)))
    }

    static func commonPrefixCount<Element: Equatable>(_ lhs: [Element], _ rhs: [Element]) -> Int {
        var index = 0
        let limit = min(lhs.count, rhs.count)
        while index < limit, lhs[index] == rhs[index] {
            index += 1
        }
        return index
    }
}
