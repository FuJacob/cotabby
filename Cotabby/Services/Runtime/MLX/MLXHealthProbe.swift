import Foundation

/// File overview:
/// Asks a running `mlx_lm.server` whether its generator is alive. A 404 on a completion does not
/// prove it died: mlx_lm 0.32.0 turns any exception inside `generate()` (a template error on one
/// bad prompt, say) into a 404 too. `GET /health` is the exact signal: it answers 503 only when
/// `generation_available()` is false and 200 otherwise. The MLX engine calls this before asking
/// the manager to restart, so one bad request cannot restart a healthy server.

/// What `/health` said.
nonisolated enum MLXServerHealth: Equatable, Sendable {
    case healthy
    case generatorDead
    /// Refused, timed out or any other transport failure: the server is not answering at all.
    case unreachable
    /// The probe itself was cancelled (the caller moved on). It says nothing about the server.
    case cancelled
}

/// Injected into the engine so tests answer without a socket.
typealias MLXHealthCheck = @Sendable (Int) async -> MLXServerHealth

nonisolated enum MLXHealthProbe {
    static func check(port: Int) async -> MLXServerHealth {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return .unreachable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 503: return .generatorDead
            case 200: return .healthy
            default: return .unreachable
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            return Task.isCancelled ? .cancelled : .unreachable
        }
    }
}
