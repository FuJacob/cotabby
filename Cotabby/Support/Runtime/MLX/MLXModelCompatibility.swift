import Foundation

/// File overview:
/// The single definition of "can `mlx_lm.server` run this repo as an autocomplete model". Three
/// callers share it so they can never disagree: the cache scanner (which downloaded models to
/// list), the custom-repo check (before any download starts) and the desire resolver (to explain a
/// selected model that was rejected). It is pure, so every rule is pinned by a unit test without a
/// file system, a network or a process. It lives in `Support/` because it is policy, not a service.
///
/// The caller supplies what it already has: the file names (a cached snapshot's, or a remote repo
/// tree's), the parsed `config.json`, and the model types the installed mlx-lm supports.

nonisolated enum MLXModelCompatibility {
    /// Why a repo cannot be used. Each case maps to one sentence for the UI.
    enum Reason: Equatable, Sendable {
        case missingConfig
        case missingWeights
        case missingTokenizer
        case unreadableConfig
        case embeddingModel
        case rerankerModel
        case speechModel
        case classifierModel
        /// The `model_type` is not in the set the installed mlx-lm supports.
        case unsupportedArchitecture(String)

        var message: String {
            switch self {
            case .missingConfig: return "No config.json."
            case .missingWeights: return "No MLX weights (.safetensors files)."
            case .missingTokenizer: return "No tokenizer files."
            case .unreadableConfig: return "config.json is unreadable or has no model_type."
            case .embeddingModel: return "Embedding model: it can't write text."
            case .rerankerModel: return "Reranker model: it can't write text."
            case .speechModel: return "Speech or audio model: it can't write text."
            case .classifierModel: return "Classifier model: it can't write text."
            case .unsupportedArchitecture(let type):
                return "Architecture “\(type)” isn't supported by the installed mlx-lm."
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case compatible(modelType: String, isInstruct: Bool)
        case incompatible(Reason)
    }

    private static let tokenizerFiles = ["tokenizer.json", "tokenizer.model", "tokenizer_config.json"]
    private static let speechNameFragments = ["tts", "whisper", "speech", "asr", "audio"]
    private static let speechArchitectureFragments = ["Speech", "CTC", "Audio"]

    /// Checks run in this order: missing files, unreadable config, what kind of model it is, then
    /// whether the installed mlx-lm knows the architecture. `supportedModelTypes` is nil when
    /// mlx-lm is not installed yet; only the architecture check is skipped then (nothing can run
    /// anyway, and hiding a downloaded model would read as "your download vanished").
    static func verdict(
        repoName: String,
        fileNames: [String],
        config: [String: Any]?,
        supportedModelTypes: Set<String>?
    ) -> Verdict {
        guard fileNames.contains("config.json") else { return .incompatible(.missingConfig) }
        guard fileNames.contains(where: { $0.hasSuffix(".safetensors") }) else { return .incompatible(.missingWeights) }
        guard fileNames.contains(where: { tokenizerFiles.contains($0) }) else { return .incompatible(.missingTokenizer) }
        guard let config, let modelType = config["model_type"] as? String else {
            return .incompatible(.unreadableConfig)
        }

        let lowerName = repoName.lowercased()
        let architectures = config["architectures"] as? [String] ?? []
        func architecture(contains fragments: [String]) -> Bool {
            architectures.contains { arch in fragments.contains { arch.contains($0) } }
        }
        if lowerName.contains("embed") || architecture(contains: ["Embedding"]) {
            return .incompatible(.embeddingModel)
        }
        if lowerName.contains("rerank") { return .incompatible(.rerankerModel) }
        if speechNameFragments.contains(where: { lowerName.contains($0) })
            || architecture(contains: speechArchitectureFragments) {
            return .incompatible(.speechModel)
        }
        if architecture(contains: ["SequenceClassification"]) { return .incompatible(.classifierModel) }

        if let supportedModelTypes, !supportedModelTypes.contains(modelType) {
            return .incompatible(.unsupportedArchitecture(modelType))
        }
        return .compatible(modelType: modelType, isInstruct: isInstructName(repoName))
    }

    /// "-it", "instruct" or "chat" as a whole `-`/`_`/`.` separated token.
    static func isInstructName(_ name: String) -> Bool {
        let tokens = name.lowercased().split(whereSeparator: { "-_.".contains($0) })
        return tokens.contains { $0 == "it" || $0 == "instruct" || $0 == "chat" }
    }
}
