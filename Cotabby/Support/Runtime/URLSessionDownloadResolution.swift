import Foundation

/// Decides how one finished URLSession download attempt resolves, from the facts its delegate
/// callbacks collected. Kept apart from `ModelDownloadSessionDelegate` so the decision can be
/// table-tested without a session, a lock, or a continuation.
nonisolated enum URLSessionDownloadResolution {
    /// Everything the delegate learned about the attempt by the time it is ready to resolve.
    nonisolated struct Facts {
        var fileURL: URL?
        var response: URLResponse?
        /// The task's completion error, or the error from rescuing the temporary file.
        var failure: Error?
        var resumeData: Data?
    }

    nonisolated enum Outcome {
        case file(URL, URLResponse)
        case paused(resumeData: Data?)
        case cancelled
        case failed(Error)
        /// The task reported success without a usable file and response.
        case badResponse
    }

    static func outcome(intent: DownloadStopIntent?, facts: Facts) -> Outcome {
        let completeFile: (URL, URLResponse)? = {
            guard let fileURL = facts.fileURL, let response = facts.response else { return nil }
            return (fileURL, response)
        }()

        switch intent {
        case .pause:
            // A pause can race with `didFinishDownloadingTo`. When the complete file was already
            // rescued, hand it over for validation instead of discarding every byte or publishing
            // a pause that has nothing to resume from.
            if let completeFile {
                return .file(completeFile.0, completeFile.1)
            }
            return .paused(resumeData: facts.resumeData)
        case .cancel:
            return .cancelled
        case nil:
            // `Task` cancellation reaches the session as a plain task cancel with no recorded
            // intent, and must still read as the user's cancel rather than a failure.
            if (facts.failure as? URLError)?.code == .cancelled {
                return .cancelled
            }
            if let failure = facts.failure {
                return .failed(failure)
            }
            if let completeFile {
                return .file(completeFile.0, completeFile.1)
            }
            return .badResponse
        }
    }
}
