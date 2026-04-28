import Foundation

/// File overview:
/// Classifies download errors into "user pressed cancel" vs "something genuinely
/// went wrong." Used by `ModelDownloadManager` to decide whether a failed
/// download should restore the prior state (cancel) or surface as `.failed`.
///
/// Why this is its own type:
/// Swift's `Task.cancel()` triggers two distinct error shapes by the time we
/// catch them downstream:
///
///   1. `CancellationError` — when `Task.checkCancellation()` runs *before* the
///      URLSession download even starts.
///   2. `URLError(.cancelled)` — when the URLSession download is in flight and
///      our `withTaskCancellationHandler` aborts it via
///      `URLSessionDownloadTask.cancel()`.
///
/// Without this classification, case (2) would route through the catch-all
/// failure path and the user would see "The operation couldn't be completed"
/// despite having pressed Cancel themselves. This helper makes the
/// distinction testable in isolation, with no URLSession or Task setup.
enum DownloadOutcomeClassifier {
    static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }
}
