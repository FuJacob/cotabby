import Foundation

/// File overview:
/// Classifies why a download stopped: the user paused it, the user cancelled it, or something
/// genuinely went wrong. `ModelDownloadManager` uses the answer to decide whether a stopped
/// download keeps its partial data (pause), restores the prior state (cancel), or surfaces as
/// `.failed`.
///
/// Why this is its own type:
/// User cancellation reaches the manager in three shapes:
///
///   1. `DownloadInterruption.cancelled` when a backend observed the cancel request itself.
///   2. `CancellationError` when `Task.checkCancellation()` runs before a backend started.
///   3. `URLError(.cancelled)` when the URLSession download is in flight and
///      `withTaskCancellationHandler` aborts it via `URLSessionDownloadTask.cancel()`.
///
/// Without this classification, case (3) would route through the catch-all failure path and the
/// user would see "The operation couldn't be completed" despite having pressed Cancel themselves.
/// This helper makes the distinction testable in isolation, with no URLSession or Task setup.
nonisolated enum DownloadOutcomeClassifier {
    nonisolated enum Stop: Equatable {
        case paused(resumeData: Data?)
        case cancelled
        case failed
    }

    static func classify(_ error: Error) -> Stop {
        if let interruption = error as? DownloadInterruption {
            switch interruption {
            case .paused(let resumeData):
                return .paused(resumeData: resumeData)
            case .cancelled:
                return .cancelled
            }
        }
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return .cancelled
        }
        return .failed
    }
}
