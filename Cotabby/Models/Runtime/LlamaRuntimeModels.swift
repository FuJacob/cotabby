import Foundation

/// File overview:
/// Shared value types for runtime bootstrap, model selection, generation options, and runtime errors.
/// These types keep runtime state serializable, testable, and separate from the service layer.
///
/// Human-readable lifecycle states surfaced to the UI during runtime bootstrap.
enum RuntimeBootstrapState: Equatable, Sendable {
    case idle
    case loading(String)
    case ready(String)
    case failed(String)

    var summary: String {
        switch self {
        case .idle:
            return "Idle"
        case .loading(let detail),
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
}

/// Downloadable model metadata used by onboarding and the Settings model catalog.
/// The source URL is the transfer identity, while `filename` is the flat on-disk destination.
/// Keeping those identities separate prevents repositories that publish the same leaf filename
/// from sharing pause, cancellation, or resume state.
struct DownloadableRuntimeModel: Equatable, Hashable, Sendable, Identifiable {
    let filename: String
    let displayName: String
    let downloadURL: URL
    let approximateSizeInGigabytes: Double
    /// Exact byte count of the served file. When non-nil, the download manager
    /// runs `ModelFileValidator.validateSize` against it before the slower
    /// checksum pass.
    let expectedSizeBytes: Int64?
    /// Lowercase SHA-256 hex string for the served file: pinned in the curated
    /// catalog, or the LFS oid the Hugging Face tree API reports for search
    /// results. Optional only so hand-built values (tests) stay cheap to write;
    /// `ModelFileValidator.validateSHA256` refuses to install a download whose
    /// digest is nil.
    let sha256: String?

    var id: String { downloadURL.absoluteString }
    var approximateSizeLabel: String { String(format: "~%.1f GB", approximateSizeInGigabytes) }

    init(
        filename: String,
        displayName: String,
        downloadURL: URL,
        approximateSizeInGigabytes: Double,
        expectedSizeBytes: Int64? = nil,
        sha256: String? = nil
    ) {
        self.filename = filename
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.approximateSizeInGigabytes = approximateSizeInGigabytes
        self.expectedSizeBytes = expectedSizeBytes
        self.sha256 = sha256
    }
}

/// Maps installed model filenames to presentation names. Rebranding these labels never changes
/// download URLs, model files, or the filenames persisted by the settings model.
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

    /// Builds a Hugging Face direct-download URL pinned to one commit of a third-party repo.
    /// `resolve/main` would follow whatever the repo publishes next; with a commit pin, a later
    /// re-upload cannot change the bytes, and a mismatch against the pinned SHA-256 fails closed.
    private static func hfURL(_ repo: String, revision: String, _ file: String) -> URL {
        // Force-unwrap is safe: inputs are compile-time literals forming a valid URL.
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)?download=true")!
    }

    /// Canonical downloadable base GGUF models for Cotabby 2's base-model continuation path.
    /// Qwen3.5 / Gemma base checkpoints from mradermacher's i1 GGUF repos. Each entry pins the repo
    /// commit, and its byte size and SHA-256 come from the Hugging Face tree API at that commit
    /// (`/api/models/<repo>/tree/<revision>`: `size` and `lfs.oid`). To move a model to a newer
    /// upload, update all three together. Old instruct GGUFs are intentionally no longer listed.
    static let downloadableModels: [DownloadableRuntimeModel] = [
        DownloadableRuntimeModel(
            filename: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf",
            displayName: displayName(for: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf"),
            downloadURL: hfURL(
                "mradermacher/Qwen3.5-0.8B-Base-i1-GGUF",
                revision: "0adcee13f1a32c38fdbdb93e21d57e76b5640836",
                "Qwen3.5-0.8B-Base.i1-Q6_K.gguf"
            ),
            approximateSizeInGigabytes: 0.8,
            expectedSizeBytes: 629_744_512,
            sha256: "febd85051361ccb34d0925744c819f9ae0724117e8f946a2852dd0edfa90a5a1"
        ),
        DownloadableRuntimeModel(
            filename: "Qwen3.5-2B-Base.i1-Q4_K_M.gguf",
            displayName: displayName(for: "Qwen3.5-2B-Base.i1-Q4_K_M.gguf"),
            downloadURL: hfURL(
                "mradermacher/Qwen3.5-2B-Base-i1-GGUF",
                revision: "209c5e51cc8ceee9b70facbcf36c57d7968ba543",
                "Qwen3.5-2B-Base.i1-Q4_K_M.gguf"
            ),
            approximateSizeInGigabytes: 1.4,
            expectedSizeBytes: 1_274_397_056,
            sha256: "e3daa3f6e5ed8de264fc6e4128713ae1eb0c2649ad69b83f97bfc6a6ddca3da8"
        ),
        DownloadableRuntimeModel(
            filename: "gemma-4-E2B.i1-Q6_K.gguf",
            displayName: displayName(for: "gemma-4-E2B.i1-Q6_K.gguf"),
            downloadURL: hfURL(
                "mradermacher/gemma-4-E2B-i1-GGUF",
                revision: "a9bf638e53783fc93778f357cc5c672eab5393b1",
                "gemma-4-E2B.i1-Q6_K.gguf"
            ),
            approximateSizeInGigabytes: 4.5,
            expectedSizeBytes: 3_845_328_608,
            sha256: "20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629"
        ),
        DownloadableRuntimeModel(
            filename: "gemma-4-E4B.i1-Q4_K_M.gguf",
            displayName: displayName(for: "gemma-4-E4B.i1-Q4_K_M.gguf"),
            downloadURL: hfURL(
                "mradermacher/gemma-4-E4B-i1-GGUF",
                revision: "8d1efb45cd65f46a70ac918584e2f0244117465f",
                "gemma-4-E4B.i1-Q4_K_M.gguf"
            ),
            approximateSizeInGigabytes: 5.0,
            expectedSizeBytes: 5_335_274_240,
            sha256: "687f4cce47eac6ccfc595fd9517215fb964e5e5be17d4774b25b8add401d6d3c"
        )
    ]

    /// How a Hugging Face repository file relates to the curated catalog by destination filename.
    enum CuratedFilenameMatch: Equatable {
        /// The filename belongs to no curated model.
        case notCurated
        /// The file is a curated model's own file in its source repository.
        case curatedSource(DownloadableRuntimeModel)
        /// A different repository (or path) publishes a file under a curated model's filename.
        /// Installing it would make third-party bytes appear under the curated display name.
        case otherSource(curatedDisplayName: String)
    }

    /// Classifies `filePath` in `repoID` against the curated catalog. Display names are keyed by
    /// filename alone, so a search download must not claim a curated filename unless it is that
    /// model's own file. Names compare case- and normalization-insensitively because the default
    /// APFS volume treats such variants as the same file.
    static func curatedFilenameMatch(filePath: String, huggingFaceRepoID repoID: String) -> CuratedFilenameMatch {
        let leafKey = filenameKey((filePath as NSString).lastPathComponent)
        guard let curated = downloadableModels.first(where: { filenameKey($0.filename) == leafKey }) else {
            return .notCurated
        }

        let isCuratedRepository = curated.downloadURL.path.lowercased()
            .hasPrefix("/\(repoID.lowercased())/resolve/")
        if isCuratedRepository && filenameKey(filePath) == filenameKey(curated.filename) {
            return .curatedSource(curated)
        }
        return .otherSource(curatedDisplayName: curated.displayName)
    }

    private static func filenameKey(_ filename: String) -> String {
        filename.precomposedStringWithCanonicalMapping.lowercased()
    }
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
        contextWindowTokens: 4096,
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
    /// Whether the engine should compute per-token log-probabilities at all. They cost two
    /// O(vocab) passes per token and only the confidence gate reads them.
    nonisolated var computesLogprob: Bool { confidenceFloor > -.infinity }

    /// Minimum tokens generated before the sentence-boundary early stop may fire. Guards against
    /// degenerate instant stops (e.g. a lone leading period). Lives here so length presets can tune
    /// the floor without reaching into `DecodeStopPolicy`; the default preserves prior behavior.
    var sentenceStopMinimumTokens: Int = 2
    /// Minimum whitespace-separated words before the sentence-boundary early stop may fire; the
    /// word-count preset's lower bound, so short sentence ends do not cut a suggestion to one word.
    var sentenceStopMinimumWords: Int = 0

    /// Stop decoding the moment the raw distribution's most-likely next token is end-of-generation,
    /// even when the stochastic sampler drew something else. The model's top choice being "stop"
    /// is the strongest anti-rambling signal available per token, and the engine computes it while
    /// the logits row is hot, so honoring it costs nothing here.
    var stopAtArgmaxEOG: Bool = true
}

/// One generation's text plus the confidence signals the caller needs for suppression accounting.
/// Returned instead of a bare string so a confidence-suppressed completion is attributed to the
/// real reason rather than reading as "the model produced nothing".
struct LlamaGenerationOutput: Equatable, Sendable {
    let text: String
    /// Mean per-token log-probability of the generated tokens; nil when confidence gating was off
    /// (the engine skips the per-token logprob work entirely) or nothing was generated.
    let averageLogprob: Double?
    /// True when the completion was withheld because `averageLogprob` fell below the floor.
    let suppressedByLowConfidence: Bool

}

/// The concrete runtime assets selected during bootstrap after checking available model files.
struct ResolvedLlamaRuntime: Equatable, Sendable {
    let modelFileURL: URL
    let modelDisplayName: String
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
