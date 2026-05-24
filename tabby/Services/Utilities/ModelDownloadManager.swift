import AppKit
import Combine
import Foundation
import Logging

/// One model's current install/download lifecycle state in local storage.
enum ModelDownloadState: Equatable {
    case idle
    case downloading(progress: Double?)
    case downloaded
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:
            return "Not installed"
        case .downloading(let progress):
            if let progress {
                return "Downloading \(Int((progress * 100).rounded()))%"
            }
            return "Downloading"
        case .downloaded:
            return "Installed"
        case .failed(let message):
            return message
        }
    }

    /// Determinate progress is only available when the server reports content length.
    /// We surface it separately so views can choose between a linear bar and an indeterminate one.
    var progressFraction: Double? {
        guard case .downloading(let progress) = self else {
            return nil
        }

        guard let progress else {
            return nil
        }

        return min(max(progress, 0), 1)
    }

    var isDownloading: Bool {
        if case .downloading = self {
            return true
        }

        return false
    }
}

/// Downloads model files on demand into a user-writable runtime directory.
/// This decouples app shipping from model shipping so model updates do not require app updates.
@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var modelStates: [String: ModelDownloadState] = [:]

    var onModelDirectoryChanged: (() -> Void)?

    private let runtimeDirectoryURL: URL
    private let runtimeSearchDirectories: [URL]
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    init(runtimeDirectoryURL: URL? = nil) {
        let primaryDirectoryURL =
            runtimeDirectoryURL ?? BundledRuntimeLocator.userRuntimeDirectoryURL()
        self.runtimeDirectoryURL = primaryDirectoryURL

        var directories = [primaryDirectoryURL]
        for directoryURL in BundledRuntimeLocator.runtimeSearchDirectories() {
            let normalizedPath = directoryURL.standardizedFileURL.path
            if !directories.contains(where: { $0.standardizedFileURL.path == normalizedPath }) {
                directories.append(directoryURL)
            }
        }
        runtimeSearchDirectories = directories

        refreshModelStates()
    }

    var models: [DownloadableRuntimeModel] {
        RuntimeModelCatalog.downloadableModels
    }

    var modelsDirectoryPath: String {
        runtimeDirectoryURL.path
    }

    func state(for model: DownloadableRuntimeModel) -> ModelDownloadState {
        modelStates[model.filename] ?? .idle
    }

    func refreshModelStates() {
        for model in models {
            if downloadTasks[model.filename] != nil {
                if case .downloading(let progress) = modelStates[model.filename] {
                    modelStates[model.filename] = .downloading(progress: progress)
                } else {
                    modelStates[model.filename] = .downloading(progress: nil)
                }
            } else if isInstalled(model: model) {
                modelStates[model.filename] = .downloaded
            } else {
                modelStates[model.filename] = .idle
            }
        }
    }

    func download(_ model: DownloadableRuntimeModel) {
        guard downloadTasks[model.filename] == nil else {
            TabbyLogger.models.debug("Download already in progress for \(model.filename)")
            return
        }

        if isInstalled(model: model) {
            TabbyLogger.models.debug("Model \(model.filename) already installed, skipping download")
            modelStates[model.filename] = .downloaded
            return
        }

        TabbyLogger.models.info("Starting download for \(model.filename)")
        modelStates[model.filename] = .downloading(progress: 0)
        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.performDownload(model)
        }
        downloadTasks[model.filename] = task
    }

    /// User-initiated cancel of an in-flight model download. Idempotent —
    /// calling it on a filename that isn't downloading is a safe no-op.
    ///
    /// Cancellation flow:
    ///   1. `Task.cancel()` flips `Task.isCancelled` and triggers the
    ///      `withTaskCancellationHandler` block in the delegate.
    ///   2. That block calls `URLSessionDownloadTask.cancel()`, which aborts
    ///      the in-flight download.
    ///   3. The delegate receives `didCompleteWithError(URLError.cancelled)`
    ///      and resumes the continuation throwing.
    ///   4. `performDownload`'s catch routes the error through
    ///      `DownloadOutcomeClassifier`, sees a user cancel, and restores
    ///      `.idle` (or `.downloaded` if a prior copy is on disk) — never
    ///      `.failed`, since the user pressed Cancel deliberately.
    func cancel(filename: String) {
        guard let task = downloadTasks[filename] else {
            return
        }
        task.cancel()
    }

    /// Cancels every in-flight model download before destructive app cleanup.
    /// Uninstall should not race an active download that may still be writing into Tabby's model
    /// directory while the folder is being removed.
    func cancelAllDownloads() {
        for task in downloadTasks.values {
            task.cancel()
        }
    }

    func openModelsDirectory() {
        do {
            try ensureRuntimeDirectoryExists()
        } catch {
            return
        }

        NSWorkspace.shared.open(runtimeDirectoryURL)
    }

    /// Returns `true` only when the concrete GGUF file lives in Tabby's user-writable model
    /// directory. This is the boundary we use for destructive actions so settings never offers
    /// "delete" for assets outside the app-managed local model directory.
    func canDeleteModel(filename: String) -> Bool {
        FileManager.default.fileExists(atPath: modelFileURL(filename: filename).path)
    }

    /// Removes one concrete GGUF file from the user-managed runtime directory.
    /// The caller decides whether deletion should be offered; this method only enforces the storage
    /// boundary and refreshes observers after a successful removal.
    func deleteModel(filename: String) {
        let fileURL = modelFileURL(filename: filename)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: fileURL)
            refreshModelStates()
            onModelDirectoryChanged?()
        } catch {
            TabbyLogger.models.error("Failed to delete model \(filename): \(error.localizedDescription)")
        }
    }

    private func performDownload(_ model: DownloadableRuntimeModel) async {
        defer {
            downloadTasks[model.filename] = nil
        }

        do {
            try ensureRuntimeDirectoryExists()
            let destinationURL = modelFileURL(filename: model.filename)
            let delegate = ModelDownloadSessionDelegate { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadTasks[model.filename] != nil else {
                        return
                    }

                    self.modelStates[model.filename] = .downloading(progress: progress)
                }
            }
            let downloadResult = try await delegate.download(from: model.downloadURL)
            try Task.checkCancellation()
            try validate(response: downloadResult.response)

            let fileManager = FileManager.default

            // Stage-validate-swap so a corrupt download can't take out a
            // working previous install. If validation throws, the staged
            // file is removed and the existing destinationURL (if any)
            // stays untouched.
            let stagingURL = runtimeDirectoryURL.appendingPathComponent(
                "\(model.filename).staging-\(UUID().uuidString)",
                isDirectory: false
            )
            try fileManager.moveItem(at: downloadResult.temporaryURL, to: stagingURL)

            do {
                try ModelFileValidator.validateSize(
                    of: stagingURL,
                    expectedBytes: model.expectedSizeBytes
                )
                try ModelFileValidator.validateSHA256(
                    of: stagingURL,
                    expectedSHA256: model.sha256
                )
            } catch {
                // Don't leave a partial or corrupt file in the runtime
                // directory where the locator might pick it up later.
                try? fileManager.removeItem(at: stagingURL)
                throw error
            }

            // Validation passed — atomically swap the new file in. The
            // existing copy is removed only at this point, so any failure
            // before here leaves the prior install intact.
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)

            TabbyLogger.models.info("Download complete for \(model.filename)")
            modelStates[model.filename] = .downloaded
            onModelDirectoryChanged?()
        } catch {
            // A user-initiated cancel surfaces here as either CancellationError
            // (cancelled before URLSession ran) or URLError.cancelled
            // (cancelled while in flight). Both should restore the prior
            // visible state, not show a failure — the user already knows what
            // they did. DownloadOutcomeClassifier owns the discrimination so
            // the rule is unit-tested in isolation.
            if DownloadOutcomeClassifier.isUserCancellation(error) {
                TabbyLogger.models.info("Download cancelled by user for \(model.filename)")
                modelStates[model.filename] = isInstalled(model: model) ? .downloaded : .idle
            } else {
                TabbyLogger.models.error("Download failed for \(model.filename): \(error.localizedDescription)")
                modelStates[model.filename] = .failed(error.localizedDescription)
            }
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LlamaRuntimeError.unavailable(
                "Model download failed with status code \(httpResponse.statusCode).")
        }
    }

    private func ensureRuntimeDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: runtimeDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func modelFileURL(filename: String) -> URL {
        runtimeDirectoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func isInstalled(model: DownloadableRuntimeModel) -> Bool {
        model.allKnownFilenames.contains(where: isInstalled(filename:))
    }

    private func isInstalled(filename: String) -> Bool {
        runtimeSearchDirectories.contains { directoryURL in
            let fileURL = directoryURL.appendingPathComponent(filename, isDirectory: false)
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
    }
}

/// Bridges `URLSessionDownloadDelegate` callbacks into one async result plus incremental progress
/// updates. This exists as its own type because `URLSession.download(from:)` gives us the file move
/// convenience but not observable progress suitable for SwiftUI.
private final class ModelDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    struct DownloadResult {
        let temporaryURL: URL
        let response: URLResponse
    }

    private let progressHandler: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<DownloadResult, Error>?
    private var downloadedFileURL: URL?
    private var response: URLResponse?
    private var hasCompleted = false
    // Held so `withTaskCancellationHandler` can call .cancel() on it when the
    // surrounding Swift Task is cancelled. Without this, Task.cancel() would
    // only flip Task.isCancelled — the URLSession download would keep running
    // until natural completion, wasting bytes and ignoring the user's intent.
    private var activeDownloadTask: URLSessionDownloadTask?
    // Any error thrown while rescuing the temp file in `didFinishDownloadingTo`.
    // We can't throw from the delegate callback, so we stash it and re-raise from
    // `didCompleteWithError`, which is the single funnel that resumes the continuation.
    private var finishError: Error?

    init(progressHandler: @escaping @Sendable (Double?) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(from url: URL) async throws -> DownloadResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        // withTaskCancellationHandler bridges Swift Task cancellation into the
        // URLSession world. When `Task.cancel()` runs upstream (e.g., from
        // ModelDownloadManager.cancel(filename:)), the onCancel block fires and
        // aborts the URLSession download task. The delegate then receives
        // didCompleteWithError(URLError.cancelled), which resumes the
        // continuation throwing — and the catch in performDownload routes it
        // through DownloadOutcomeClassifier as a user cancel rather than a
        // hard failure.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(with: url)
                self.activeDownloadTask = task
                task.resume()
            }
        } onCancel: { [weak self] in
            // URLSessionDownloadTask.cancel() is thread-safe by Apple's docs,
            // so calling it from arbitrary cancellation contexts is fine.
            self?.activeDownloadTask?.cancel()
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
        } else {
            progress = nil
        }

        progressHandler(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Synchronous handoff into a URL we own. The rescue logic lives in
        // `DownloadFileRescuer` so the race-sensitive part can be unit-tested
        // without standing up a real URLSession — see that type's doc comment
        // for why the move must happen before this callback returns.
        do {
            downloadedFileURL = try DownloadFileRescuer.rescue(temporaryFileAt: location)
        } catch {
            // Can't throw from a delegate callback; stash and re-raise from
            // `didCompleteWithError`, the single funnel that resumes the
            // continuation.
            finishError = error
        }
        response = downloadTask.response
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !hasCompleted else {
            return
        }
        hasCompleted = true

        defer {
            continuation = nil
            session.finishTasksAndInvalidate()
        }

        // Surface transport errors first, then the delegate-side rescue error. Either way we
        // must clean up any holding file we already claimed so failed downloads don't leak.
        if let failure = error ?? finishError {
            if let holdingURL = downloadedFileURL {
                DownloadFileRescuer.cleanup(holdingFileAt: holdingURL)
                downloadedFileURL = nil
            }
            continuation?.resume(throwing: failure)
            return
        }

        guard let downloadedFileURL, let response else {
            continuation?.resume(throwing: URLError(.badServerResponse))
            return
        }

        continuation?.resume(
            returning: DownloadResult(temporaryURL: downloadedFileURL, response: response))
    }
}
