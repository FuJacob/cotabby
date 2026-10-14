import Foundation

/// File overview:
/// The one rule that turns "what the user chose" plus "what this Mac has" into "what the MLX
/// server should be doing". `CotabbyAppEnvironment` re-evaluates it whenever any input publishes
/// and hands the answer to `MLXServerManager.apply(_:)`. Being pure, it is where every
/// combination is pinned by a test, instead of being scattered through Combine sinks.

/// Exactly what to launch. Equality decides whether a running server must restart.
nonisolated struct MLXServerLaunch: Equatable, Sendable {
    let executable: URL
    let modelID: String
    let promptCacheBytes: Int
}

/// The answer the resolver gives: stop, explain why not, or run this exact launch. A plain value
/// with no behavior, so `MLXServerManager` can diff the previous and new answers and act only on a
/// change. Its lifetime is one resolver call; nothing stores it.
nonisolated enum MLXServerDesire: Equatable, Sendable {
    /// MLX is not selected, or a prerequisite is still being checked or installed.
    case stopped
    /// MLX is selected but cannot run; the reason is shown to the user.
    case unavailable(MLXUnavailableReason)
    case running(MLXServerLaunch)
}

/// The pure decision table behind "should the MLX server run, and with what". It owns no state and
/// has no collaborators: the caller gathers the inputs (engine setting, hardware, toolchain state,
/// selected model, cache scan) and passes them in. It is a caseless enum namespace rather than a
/// struct because there is nothing to construct, and it lives in `Support/` so every combination
/// stays testable without a process, a file system or Combine.
nonisolated enum MLXServerDesireResolver {
    static func desire(
        engine: SuggestionEngineKind,
        isAppleSilicon: Bool,
        toolchain: MLXToolchainState,
        modelID: String,
        cachedModels: [MLXCachedModel]?,
        promptCacheBytes: Int,
        rejectedModels: [MLXRepoID: MLXModelCompatibility.Reason] = [:]
    ) -> MLXServerDesire {
        guard engine == .mlx else { return .stopped }
        guard isAppleSilicon else { return .unavailable(.unsupportedHardware) }
        switch toolchain {
        case .checking, .installing:
            // Transient: reporting "not installed" here would flash an attention dot at every launch.
            return .stopped
        case .notInstalled, .tooOld, .failed:
            return .unavailable(.notInstalled)
        case .ready(let toolchain):
            guard let repoID = MLXRepoID(modelID) else { return .unavailable(.noModel) }
            // The first cache scan has not finished: wait rather than claim the model is missing.
            guard let cachedModels else { return .stopped }
            guard cachedModels.contains(where: { $0.repoID == repoID }) else {
                // Downloaded but turned away by the compatibility rule: say why, not "download it".
                if let reason = rejectedModels[repoID] {
                    return .unavailable(.modelIncompatible(repoID, reason.message))
                }
                return .unavailable(.modelNotDownloaded(repoID))
            }
            return .running(MLXServerLaunch(
                executable: toolchain.serverExecutable,
                modelID: repoID.value,
                promptCacheBytes: promptCacheBytes
            ))
        }
    }
}
