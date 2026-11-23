import Foundation

/// File overview:
/// Self-cancels an inline-command capture that sits untouched, so a picker or preview never lingers
/// (and the active tap never stays installed) if the user walks away mid-query. Each controller
/// owns one and re-arms it on every interaction.
@MainActor
final class InlineCaptureIdleTimer {
    /// Generous because the user may pause to read the matches or the previewed result.
    static let timeoutNanoseconds: UInt64 = 8_000_000_000

    private var task: Task<Void, Never>?

    /// Restarts the countdown. `onExpire` should capture its owner weakly: the pending task keeps
    /// the closure alive for the full timeout.
    func arm(onExpire: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            onExpire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
