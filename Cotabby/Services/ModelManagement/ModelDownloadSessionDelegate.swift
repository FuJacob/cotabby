import Foundation

nonisolated enum ModelDownloadSessionError: LocalizedError, Equatable {
    case alreadyStarted

    var errorDescription: String? {
        String(localized: "A model download session can only be started once.")
    }
}

/// Bridges URLSession's callback lifecycle into one async download result with pause data.
/// `ModelDownloadManager` owns an instance only while a fallback download is active; the lock
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

    private let progressHandler: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadResult, Error>?
    private var downloadedFileURL: URL?
    private var response: URLResponse?
    private var expectedFileSize: Int64 = NSURLSessionTransferSizeUnknown
    private var producedResumeData: Data?
    private var hasStarted = false
    private var hasCompleted = false
    private var didReceiveTaskCompletion = false
    private var activeDownloadTask: URLSessionDownloadTask?
    private var finishError: Error?
    private var taskCompletionError: Error?
    private var isUserPaused = false
    private var isUserCancelled = false
    private var isPauseResumeDataPending = false

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
                if self.hasStarted {
                    self.lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: ModelDownloadSessionError.alreadyStarted)
                    return
                }
                self.hasStarted = true
                if self.isUserCancelled {
                    self.lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if self.isUserPaused {
                    self.lock.unlock()
                    session.invalidateAndCancel()
                    continuation.resume(throwing: URLSessionDownloadInterruption.paused(resumeData: nil))
                    return
                }

                self.continuation = continuation
                let task: URLSessionDownloadTask
                if let resumeData {
                    task = session.downloadTask(withResumeData: resumeData)
                } else {
                    task = session.downloadTask(with: url)
                }
                self.activeDownloadTask = task
                self.lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel()
        }
    }

    func pause() {
        let task = lock.withLock { () -> URLSessionDownloadTask? in
            guard !isUserCancelled, !isUserPaused else {
                return nil
            }
            isUserPaused = true
            guard let activeDownloadTask else {
                return nil
            }
            isPauseResumeDataPending = true
            return activeDownloadTask
        }

        task?.cancel(byProducingResumeData: { [weak self] resumeData in
            self?.didProducePauseResumeData(resumeData)
        })
    }

    func cancel() {
        let state = lock.withLock { () -> (URLSessionDownloadTask?, CompletionState?) in
            isUserPaused = false
            isUserCancelled = true
            isPauseResumeDataPending = false
            producedResumeData = nil
            return (activeDownloadTask, takeCompletionLocked())
        }

        state.0?.cancel()
        if let completion = state.1 {
            resolve(completion)
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
                downloadedFileURL = rescued
                response = downloadTask.response
            }
        } catch {
            lock.withLock {
                finishError = error
                response = downloadTask.response
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion = lock.withLock { () -> CompletionState? in
            didReceiveTaskCompletion = true
            taskCompletionError = error
            if isUserPaused, !isUserCancelled,
               let errorResumeData = (error as? NSError)?
               .userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                producedResumeData = errorResumeData
            }
            if isUserPaused && isPauseResumeDataPending {
                return nil
            }
            return takeCompletionLocked()
        }

        defer { session.finishTasksAndInvalidate() }
        if let completion {
            resolve(completion)
        }
    }

    /// URLSession may invoke task completion before the resume-data callback. Waiting for both
    /// prevents the manager from publishing `.paused` with no bytes available to resume.
    private func didProducePauseResumeData(_ resumeData: Data?) {
        let completion = lock.withLock { () -> CompletionState? in
            isPauseResumeDataPending = false
            if !isUserCancelled, let resumeData {
                producedResumeData = resumeData
            }
            return takeCompletionLocked()
        }
        if let completion {
            resolve(completion)
        }
    }

    private func takeCompletionLocked() -> CompletionState? {
        guard didReceiveTaskCompletion, !hasCompleted else {
            return nil
        }
        hasCompleted = true
        activeDownloadTask = nil
        defer { continuation = nil }
        return CompletionState(
            continuation: continuation,
            paused: isUserPaused,
            cancelled: isUserCancelled,
            fileURL: downloadedFileURL,
            response: response,
            expectedFileSize: expectedFileSize,
            failure: taskCompletionError ?? finishError,
            resumeData: producedResumeData
        )
    }

    private func resolve(_ completion: CompletionState) {
        let hasCompleteFile = completion.fileURL != nil && completion.response != nil
        if completion.paused && !hasCompleteFile {
            if let fileURL = completion.fileURL {
                DownloadFileRescuer.cleanup(holdingFileAt: fileURL)
            }
            completion.continuation?.resume(
                throwing: URLSessionDownloadInterruption.paused(
                    resumeData: completion.resumeData
                )
            )
            return
        }

        // A pause can race with `didFinishDownloadingTo`. When the complete file was already
        // rescued, return it for validation instead of discarding all bytes or publishing a pause
        // that has no resume data.
        if !completion.paused,
           completion.cancelled || (completion.failure as? URLError)?.code == .cancelled {
            cleanupAndResume(completion, error: CancellationError())
            return
        }

        if !completion.paused, let failure = completion.failure {
            cleanupAndResume(completion, error: failure)
            return
        }

        guard let fileURL = completion.fileURL, let response = completion.response else {
            if let fileURL = completion.fileURL {
                DownloadFileRescuer.cleanup(holdingFileAt: fileURL)
            }
            completion.continuation?.resume(throwing: URLError(.badServerResponse))
            return
        }

        completion.continuation?.resume(
            returning: DownloadResult(
                temporaryURL: fileURL,
                response: response,
                expectedFileSize: completion.expectedFileSize
            )
        )
    }

    private func cleanupAndResume(_ completion: CompletionState, error: Error) {
        if let fileURL = completion.fileURL {
            DownloadFileRescuer.cleanup(holdingFileAt: fileURL)
        }
        completion.continuation?.resume(throwing: error)
    }
}

/// Carries resume data across the async boundary before the manager publishes `.paused`.
nonisolated enum URLSessionDownloadInterruption: Error {
    case paused(resumeData: Data?)
}

/// Immutable callback snapshot so completion logic runs without holding the delegate's lock.
nonisolated private struct CompletionState {
    let continuation: CheckedContinuation<ModelDownloadSessionDelegate.DownloadResult, Error>?
    let paused: Bool
    let cancelled: Bool
    let fileURL: URL?
    let response: URLResponse?
    let expectedFileSize: Int64
    let failure: Error?
    let resumeData: Data?
}
