import Foundation

/// File overview:
/// Decides whether a failed request to Cotabby's own loopback `mlx_lm.server` *looks like* a dead
/// generator. mlx_lm 0.32.0 answers HTTP 404 (`{"error": "generation thread died"}`) in that case
/// while the process and `/v1/models` stay up, so process-exit monitoring never notices. But its
/// `handle_completion` also maps any exception from `generate()` (tokenizer or chat-template error,
/// a model-load error) to 404, and it never returns 500. So this is only a suspicion: callers must
/// confirm with `GET /health` (`MLXHealthProbe`, 503 only when the generator is gone) before a
/// restart.
nonisolated enum MLXGeneratorFailure {
    /// A short reason when `error` could mean the generator is gone, otherwise nil.
    static func reason(for error: Error) -> String? {
        guard let clientError = error as? OpenAICompatibleClientError else { return nil }
        switch clientError {
        case .server(let statusCode) where statusCode == 404:
            return "HTTP 404"
        case .streamError(let message) where message.contains("generation thread died"):
            return "generation thread died"
        default:
            return nil
        }
    }
}
