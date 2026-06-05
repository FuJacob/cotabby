import Foundation

/// File overview:
/// Shared value types for runtime bootstrap, model selection, diagnostics, and runtime errors.
/// These types keep runtime state serializable, testable, and separate from the service layer.
///
/// Human-readable lifecycle states surfaced to the UI during runtime bootstrap.
enum RuntimeBootstrapState: Equatable, Sendable {
    case idle
    case starting(String)
    case loading(String)
    case ready(String)
    case failed(String)

    var summary: String {
        switch self {
        case .idle:
            return "Idle"
        case .starting(let detail),
            .loading(let detail),
            .ready(let detail),
            .failed(let detail):
            return detail
        }
    }

    /// Convenience accessor for callers that only care about the failed case (e.g. the Settings
    /// sidebar's attention evaluator). Returns `nil` for healthy states so the call site stays a
    /// single `if let` rather than a multi-case switch.
    var failureDetail: String? {
        if case .failed(let detail) = self {
            return detail
        }
        return nil
    }
}

/// One discovered GGUF model option that can be displayed in the menu and loaded at runtime.
/// Known built-in filenames are mapped to product-facing aliases, while unknown custom uploads
/// intentionally fall back to their raw filename so user-provided models stay selectable.
struct RuntimeModelOption: Equatable, Hashable, Sendable, Identifiable {
    let filename: String
    let url: URL

    var id: String { filename }
    var displayName: String { RuntimeModelCatalog.displayName(for: filename) }
    var actualModelName: String { filename }
}

/// Downloadable model metadata used by onboarding and menu-based model installation.
/// Keeping this as app-level data lets us update app code and model artifacts independently.
struct DownloadableRuntimeModel: Equatable, Hashable, Sendable, Identifiable {
    let filename: String
    let displayName: String
    let downloadURL: URL
    let approximateSizeInGigabytes: Double
    /// Exact byte count of the served file. Optional so future catalog entries
    /// can land while metadata is still being filled in. When non-nil, the
    /// download manager runs `ModelFileValidator.validateSize` against it
    /// before promoting the staged file into the install location.
    let expectedSizeBytes: Int64?
    /// Lowercase SHA-256 hex string for the served file. Same nullability
    /// rationale as `expectedSizeBytes`. HuggingFace exposes this as the
    /// `x-linked-etag` response header on its CDN URLs.
    let sha256: String?
    let alternateFilenames: [String]

    var id: String { filename }
    var actualModelName: String { filename }
    var approximateSizeLabel: String { String(format: "~%.1f GB", approximateSizeInGigabytes) }

    var allKnownFilenames: [String] {
        [filename] + alternateFilenames
    }

    init(
        filename: String,
        displayName: String,
        downloadURL: URL,
        approximateSizeInGigabytes: Double,
        expectedSizeBytes: Int64? = nil,
        sha256: String? = nil,
        alternateFilenames: [String] = []
    ) {
        self.filename = filename
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.approximateSizeInGigabytes = approximateSizeInGigabytes
        self.expectedSizeBytes = expectedSizeBytes
        self.sha256 = sha256
        self.alternateFilenames = alternateFilenames
    }
}

enum RuntimeModelCatalog {
    static func displayName(for filename: String) -> String {
        switch filename {
        case "Qwen3.5-0.8B-Base.i1-Q6_K.gguf":
            return "tabby-2-nano"
        case "Qwen3.5-2B-Base.i1-Q4_K_M.gguf":
            return "tabby-2-mini"
        case "gemma-4-E2B.i1-Q6_K.gguf":
            return "tabby-2-base"
        case "gemma-4-E4B.i1-Q4_K_M.gguf":
            return "tabby-2-pro"
        default:
            return filename
        }
    }

    /// Builds a HuggingFace direct-download URL from a repo and file path.
    private static func hfURL(_ repo: String, _ file: String) -> URL {
        // Force-unwrap is safe: inputs are compile-time literals forming a valid URL.
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)?download=true")!
    }

    /// Canonical downloadable base GGUF models for Cotabby 2's base-model continuation path.
    /// Qwen3.5 / Gemma base checkpoints from mradermacher's i1 GGUF repos. `expectedSizeBytes` and
    /// `sha256` stay nil pending CDN-header capture; the download manager skips size/hash
    /// validation when they are nil. Old instruct GGUFs are intentionally no longer listed.
    static let downloadableModels: [DownloadableRuntimeModel] = [
        DownloadableRuntimeModel(
            filename: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf",
            displayName: displayName(for: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf"),
            downloadURL: hfURL("mradermacher/Qwen3.5-0.8B-Base-i1-GGUF", "Qwen3.5-0.8B-Base.i1-Q6_K.gguf"),
            approximateSizeInGigabytes: 0.8
        ),
        DownloadableRuntimeModel(
            filename: "Qwen3.5-2B-Base.i1-Q4_K_M.gguf",
            displayName: displayName(for: "Qwen3.5-2B-Base.i1-Q4_K_M.gguf"),
            downloadURL: hfURL("mradermacher/Qwen3.5-2B-Base-i1-GGUF", "Qwen3.5-2B-Base.i1-Q4_K_M.gguf"),
            approximateSizeInGigabytes: 1.4
        ),
        DownloadableRuntimeModel(
            filename: "gemma-4-E2B.i1-Q6_K.gguf",
            displayName: displayName(for: "gemma-4-E2B.i1-Q6_K.gguf"),
            downloadURL: hfURL("mradermacher/gemma-4-E2B-i1-GGUF", "gemma-4-E2B.i1-Q6_K.gguf"),
            approximateSizeInGigabytes: 4.5
        ),
        DownloadableRuntimeModel(
            filename: "gemma-4-E4B.i1-Q4_K_M.gguf",
            displayName: displayName(for: "gemma-4-E4B.i1-Q4_K_M.gguf"),
            downloadURL: hfURL("mradermacher/gemma-4-E4B-i1-GGUF", "gemma-4-E4B.i1-Q4_K_M.gguf"),
            approximateSizeInGigabytes: 5.0
        )
    ]
}

/// Startup configuration that controls which GGUF model to load and how large the runtime should be.
struct LlamaRuntimeConfiguration: Equatable, Sendable {
    let runtimeDirectoryPath: String?
    let preferredModelNames: [String]
    let contextWindowTokens: Int32
    let batchSize: Int32
    let gpuLayerCount: Int32

    /// Order matters here: the locator picks the first GGUF that exists.
    /// This list defines priority for known models; user-added GGUF files are still discoverable.
    static let `default` = LlamaRuntimeConfiguration(
        runtimeDirectoryPath: nil,
        preferredModelNames: [
            "gemma-4-E2B.i1-Q6_K.gguf",
            "Qwen3.5-2B-Base.i1-Q4_K_M.gguf",
            "Qwen3.5-0.8B-Base.i1-Q6_K.gguf",
            "gemma-4-E4B.i1-Q4_K_M.gguf"
        ],
        contextWindowTokens: 2048,
        batchSize: 512,
        gpuLayerCount: -1
    )
}

/// Sampling and length controls for one llama generation request.
///
/// These values travel together from the suggestion layer to the runtime. Modeling them as one
/// value object keeps runtime APIs small and makes cache invalidation easier to reason about:
/// changing any option means the request belongs to a different sampling configuration.
struct LlamaGenerationOptions: Equatable, Sendable {
    let maxPredictionTokens: Int
    let temperature: Double
    let topK: Int
    let topP: Double
    let minP: Double
    let repetitionPenalty: Double
    var seed: UInt32?

    /// Masks line-break tokens so single-line fields never receive a multi-line completion.
    var singleLine: Bool = false
    /// Constrains the first generated token to continue the current word (mid-word carets only).
    var forceWordContinuation: Bool = false

    /// Average per-token log-probability below which a completion is suppressed as low-confidence.
    /// Defaults to -infinity, which disables suppression entirely.
    var confidenceFloor: Double = -.infinity
}

/// The concrete runtime assets selected during bootstrap after checking available model files.
struct ResolvedLlamaRuntime: Equatable, Sendable {
    let runtimeDirectoryURL: URL
    let modelFileURL: URL
    let modelDisplayName: String
}

/// Operator-facing runtime metadata used by the menu and startup diagnostics.
struct LlamaRuntimeDiagnostics: Equatable, Sendable {
    var runtimeDirectoryPath: String?
    var modelFilePath: String?
    var backendName: String?
    var contextWindowTokens: Int?
    var batchSize: Int?
    var threadCount: Int?
    var gpuLayerCount: Int?
    var lastLoadStatus: String?
    var lastError: String?
}

/// Runtime failures surfaced before or during in-process generation.
enum LlamaRuntimeError: LocalizedError {
    case unavailable(String)
    case cancelled
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .generationFailed(let message):
            return message
        case .cancelled:
            return "Runtime work was cancelled."
        }
    }
}
