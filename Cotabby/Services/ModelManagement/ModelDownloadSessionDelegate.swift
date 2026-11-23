import Foundation

nonisolated enum ModelDownloadSessionError: LocalizedError, Equatable {
    case alreadyStarted

    var errorDescription: String? {
        "A model download session can only be started once."
    }
}

/// Bridges URLSession's callback lifecycle into one async download result with pause data.
/// `ModelDownloadManager` owns an instance only while a download is active; the lock
/// serializes delegate queues, UI cancellation, and continuation completion. Each instance owns
/// exactly one attempt because URLSession delegate completion state cannot be safely reset.
nonisolated final class ModelDownloadSessionDelegate:
    NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable {
    struct DownloadResult {
        let temporaryURL: URL
        let response: URLResponse
        let expectedFileSize: Int64
    }

    /// The single attempt's lifecycle. Everything that only exists while a task is live (the
    /// task, the continuation, which callbacks are still owed) is carried by `.active`, so a
    /// resolved or never-started attempt cannot hold a stale continuation.
    private enum Phase {
        case idle
        case active(Attempt)
        case resolved
    }

    private struct Attempt {
        let task: URLSessionDownloadTask
        let continuation: CheckedContinuation<DownloadResult, Error>
        var owed: OwedCallbacks = .taskCompletion
    }

    /// The callbacks URLSession still has to deliver before the attempt may resolve.
    /// `cancel(byProducingResumeData:)` and `didCompleteWithError` arrive in either order, and
    /// resolving a pause after only one of them would publish `.paused` with no bytes to resume.
    private enum OwedCallbacks {
        case taskCompletion
        case taskCompletionAndPauseData
        case pauseData
    }

    /// Snapshot taken under the lock so the continuation is resumed without holding it.
    private struct Resolution {
        let continuation: CheckedContinuation<DownloadResult, Error>
        let intent: DownloadStopIntent?
        let facts: URLSessionDownloadResolution.Facts
        let expectedFileSize: Int64
    }

    private let progressHandler: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var phase: Phase = .idle
    /// Recorded even before the attempt starts, so a pause or cancel that beats `download` wins.
    private var stopIntent: DownloadStopIntent?
    private var facts = URLSessionDownloadResolution.Facts()
    private var expectedFileSize: Int64 = NSURLSessionTransferSizeUnknown
    /// Kept apart from `facts.failure` until the task completes, because the task's own error
    /// takes precedence when both exist.
    private var rescueError: Error?

    init(progressHandler: @escaping @Sendable (Double?) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(from url: URL, resumeData: Data? = nil) async throws -> DownloadResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.lock.lock()
                guard case .idle = self.phase else {
                    self.lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: ModelDownloadSessionError.alreadyStarted)
                    return
                }
                switch self.stopIntent {
                case .cancel:
                    self.phase = .resolved
                    self.lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                case .pause:
                    self.phase = .resolved
                    self.lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: DownloadInterruption.paused(resumeData: nil))
                    return
                case nil:
                    break
                }

                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }
                self.phase = .active(Attempt(task: task, continuation: continuation))
                self.lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func pause() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            guard stopIntent == nil else {
                return nil
            }
            stopIntent = .pause
            guard case .active(var attempt) = phase else {
                return nil
            }
            attempt.owed = .taskCompletionAndPauseData
            phase = .active(attempt)
            return attempt.task
        }

        task?.cancel(byProducingResumeData: { [weak self] resumeData in
            self?.didProducePauseResumeData(resumeData)
        })
    }

    func cancel() {
        let (task, resolution) = lock.withLock { () -> (URLSessionDownloadTask?, Resolution?) in
            stopIntent = .cancel
            facts.resumeData = nil
            guard case .active(var attempt) = phase else {
                return (nil, nil)
            }
            switch attempt.owed {
            case .taskCompletion:
                return (attempt.task, nil)
            case .taskCompletionAndPauseData:
                // A cancel no longer needs the resume data, so only the task's own completion
                // is worth waiting for.
                attempt.owed = .taskCompletion
                phase = .active(attempt)
                return (attempt.task, nil)
            case .pauseData:
                return (attempt.task, resolveLocked(attempt))
            }
        }

        task?.cancel()
        if let resolution {
            resume(resolution)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: Double?
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            lock.withLock {
                expectedFileSize = totalBytesExpectedToWrite
            }
        } else {
            progress = nil
        }

        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        lock.withLock {
            expectedFileSize = expectedTotalBytes
        }
        guard expectedTotalBytes > 0 else {
            progressHandler(nil)
            return
        }
        progressHandler(Double(fileOffset) / Double(expectedTotalBytes))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let rescued = try DownloadFileRescuer.rescue(temporaryFileAt: location)
            lock.withLock {
                facts.fileURL = rescued
                facts.response = downloadTask.response
            }
        } catch {
            lock.withLock {
                rescueError = error
                facts.response = downloadTask.response
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let resolution = lock.withLock { () -> Resolution? in
            guard case .active(var attempt) = phase else {
                return nil
            }
            // The task's own error outranks a failure to rescue the temporary file.
            facts.failure = error ?? rescueError
            if stopIntent == .pause,
               let errorResumeData = (error as? NSError)?
               .userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                facts.resumeData = errorResumeData
            }
            switch attempt.owed {
            case .taskCompletion:
                return resolveLocked(attempt)
            case .taskCompletionAndPauseData:
                attempt.owed = .pauseData
                phase = .active(attempt)
                return nil
            case .pauseData:
                return nil
            }
        }

        defer { session.finishTasksAndInvalidate() }
        if let resolution {
            resume(resolution)
        }
    }

    private func didProducePauseResumeData(_ resumeData: Data?) {
        let resolution = lock.withLock { () -> Resolution? in
            if stopIntent != .cancel, let resumeData {
                facts.resumeData = resumeData
            }
            guard case .active(var attempt) = phase else {
                return nil
            }
            switch attempt.owed {
            case .taskCompletion:
                // A cancel already stopped waiting for this callback.
                return nil
            case .taskCompletionAndPauseData:
                attempt.owed = .taskCompletion
                phase = .active(attempt)
                return nil
            case .pauseData:
                return resolveLocked(attempt)
            }
        }
        if let resolution {
            resume(resolution)
        }
    }

    /// Must be called with `lock` held. Leaving `.active` is what guarantees the continuation is
    /// resumed exactly once, whichever callback or request gets here first.
    private func resolveLocked(_ attempt: Attempt) -> Resolution {
        phase = .resolved
        return Resolution(
            continuation: attempt.continuation,
            intent: stopIntent,
            facts: facts,
            expectedFileSize: expectedFileSize
        )
    }

    private func resume(_ resolution: Resolution) {
        let outcome = URLSessionDownloadResolution.outcome(intent: resolution.intent, facts: resolution.facts)
        if case .file(let fileURL, let response) = outcome {
            resolution.continuation.resume(
                returning: DownloadResult(
                    temporaryURL: fileURL,
                    response: response,
                    expectedFileSize: resolution.expectedFileSize
                )
            )
            return
        }

        // Every other outcome abandons whatever was rescued out of URLSession's temporary area.
        if let fileURL = resolution.facts.fileURL {
            DownloadFileRescuer.cleanup(holdingFileAt: fileURL)
        }
        switch outcome {
        case .file:
            break
        case .paused(let resumeData):
            resolution.continuation.resume(throwing: DownloadInterruption.paused(resumeData: resumeData))
        case .cancelled:
            resolution.continuation.resume(throwing: CancellationError())
        case .failed(let error):
            resolution.continuation.resume(throwing: error)
        case .badResponse:
            resolution.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
