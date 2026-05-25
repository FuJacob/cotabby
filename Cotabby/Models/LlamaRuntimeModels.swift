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
            return "Cotabby-fast-1"
        case "gemma-3-1b-it-Q4_K_M.gguf":
            return "Cotabby-balanced-1"
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
            filename: "gemma-3-1b-it-Q4_K_M.gguf",
            displayName: displayName(for: "gemma-3-1b-it-Q4_K_M.gguf"),
            downloadURL: URL(
                string:
                    "https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf?download=true"
            )!,
            approximateSizeInGigabytes: 0.8,
            expectedSizeBytes: 806_058_272,
            sha256: "8270790f3ab69fdfe860b7b64008d9a19986d8df7e407bb018184caa08798ebd"
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
            "gemma-3-1b-it-Q4_K_M.gguf",
            "Qwen3-0.6B-Q4_K_M.gguf"
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
