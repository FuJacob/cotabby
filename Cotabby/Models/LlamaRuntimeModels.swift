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
        case "Qwen3-0.6B-Q4_K_M.gguf":
            return "tabby-fast-1"
        case "gemma-4-E2B-it-Q4_K_M.gguf":
            return "tabby-balanced-1"
        case "gemma-4-E4B-it-Q4_K_M.gguf":
            return "tabby-max-1"
        case "SmolLM2-135M-Instruct-q8_0.gguf":
            return "tabby-nano-2"
        default:
            return filename
        }
    }

    /// Canonical downloadable GGUF model list shown in Welcome and menu UI.
    ///
    /// `expectedSizeBytes` and `sha256` were captured from HuggingFace's CDN
    /// response headers (`x-linked-size` and `x-linked-etag` respectively).
    /// To refresh after a model is updated upstream:
    ///
    ///   curl -sIL "<URL>" | grep -iE "^(x-linked-size|x-linked-etag):"
    static let downloadableModels: [DownloadableRuntimeModel] = [
        DownloadableRuntimeModel(
            filename: "SmolLM2-135M-Instruct-q8_0.gguf",
            displayName: displayName(for: "SmolLM2-135M-Instruct-q8_0.gguf"),
            downloadURL: URL(
                string:
                    "https://huggingface.co/Mungert/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-q8_0.gguf?download=true"
            )!,
            approximateSizeInGigabytes: 0.1,
            expectedSizeBytes: 144_811_552,
            sha256: "bc64cce8e1c11e4ed870633b557e04af718249c817c4cf8a6784116144ec3e28"
        ),
        DownloadableRuntimeModel(
            filename: "Qwen3-0.6B-Q4_K_M.gguf",
            displayName: displayName(for: "Qwen3-0.6B-Q4_K_M.gguf"),
            downloadURL: URL(
                string:
                    "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf?download=true"
            )!,
            approximateSizeInGigabytes: 0.4,
            expectedSizeBytes: 396_705_472,
            sha256: "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a"
        ),
        DownloadableRuntimeModel(
            filename: "gemma-4-E2B-it-Q4_K_M.gguf",
            displayName: displayName(for: "gemma-4-E2B-it-Q4_K_M.gguf"),
            downloadURL: URL(
                string:
                    "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf?download=true"
            )!,
            approximateSizeInGigabytes: 3.1,
            expectedSizeBytes: 3_106_736_256,
            sha256: "9378bc471710229ef165709b62e34bfb62231420ddaf6d729e727305b5b8672d"
        ),
        DownloadableRuntimeModel(
            filename: "gemma-4-E4B-it-Q4_K_M.gguf",
            displayName: displayName(for: "gemma-4-E4B-it-Q4_K_M.gguf"),
            downloadURL: URL(
                string:
                    "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf?download=true"
            )!,
            approximateSizeInGigabytes: 5.0,
            expectedSizeBytes: 4_977_169_568,
            sha256: "519b9793ed6ce0ff530f1b7c96e848e08e49e7af4d57bb97f76215963a54146d"
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
            "gemma-4-E4B-it-Q4_K_M.gguf",
            "gemma-4-E2B-it-Q4_K_M.gguf",
            "Qwen3-0.6B-Q4_K_M.gguf",
            "SmolLM2-135M-Instruct-q8_0.gguf"
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

    static func summary(maxPredictionTokens: Int, temperature: Double) -> LlamaGenerationOptions {
        LlamaGenerationOptions(
            maxPredictionTokens: maxPredictionTokens,
            temperature: temperature,
            topK: 40,
            topP: 0.95,
            minP: 0.05,
            // Higher penalty than autocomplete (1.05) because summaries span more tokens and
            // are more prone to looping when OCR input contains repeated phrases.
            repetitionPenalty: 1.4
        )
    }
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
