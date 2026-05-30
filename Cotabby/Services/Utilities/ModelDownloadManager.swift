import AppKit
import Combine
import Foundation
import Logging
import UniformTypeIdentifiers

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
    private var runtimeSearchDirectories: [URL]
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
        BundledRuntimeLocator.customModelDirectoryURL()?.path ?? runtimeDirectoryURL.path
    }

    /// Re-reads the current search directories (including any custom path) and refreshes model states.
    func refreshSearchDirectories() {
        var directories = [runtimeDirectoryURL]
        for directoryURL in BundledRuntimeLocator.runtimeSearchDirectories() {
            let normalizedPath = directoryURL.standardizedFileURL.path
            if !directories.contains(where: { $0.standardizedFileURL.path == normalizedPath }) {
                directories.append(directoryURL)
            }
        }
        runtimeSearchDirectories = directories
        refreshModelStates()
    }

    func state(for model: DownloadableRuntimeModel) -> ModelDownloadState {
        modelStates[model.filename] ?? .idle
    }

    func refreshModelStates() {
        let catalogFilenames = Set(models.map(\.filename))

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

        var keysToRemove: [String] = []
        for (filename, state) in modelStates where !catalogFilenames.contains(filename) {
            if downloadTasks[filename] != nil {
                continue
            }
            switch state {
            case .downloading:
                break
            case .downloaded, .idle, .failed:
                if isInstalled(filename: filename) {
                    modelStates[filename] = .downloaded
                } else {
                    keysToRemove.append(filename)
                }
            }
        }
        for key in keysToRemove {
            modelStates.removeValue(forKey: key)
        }
    }

    func isModelInstalled(filename: String) -> Bool {
        isInstalled(filename: filename)
    }

    func download(_ model: DownloadableRuntimeModel) {
        guard downloadTasks[model.filename] == nil else {
            CotabbyLogger.models.debug("Download already in progress for \(model.filename)")
            return
        }

        if isInstalled(model: model) {
            CotabbyLogger.models.debug("Model \(model.filename) already installed, skipping download")
            modelStates[model.filename] = .downloaded
            return
        }

        CotabbyLogger.models.info("Starting download for \(model.filename)")
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
    /// Uninstall should not race an active download that may still be writing into Cotabby's model
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
            CotabbyLogger.models.error(
                "Failed to ensure runtime directory before opening: \(error.localizedDescription)",
                metadata: ["directory": .string(runtimeDirectoryURL.path)]
            )
            return
        }

        NSWorkspace.shared.open(runtimeDirectoryURL)
    }

    func importModel() {
        let panel = NSOpenPanel()
        panel.title = "Select a GGUF Model"
        if let ggufType = UTType(filenameExtension: "gguf", conformingTo: .data) {
            panel.allowedContentTypes = [ggufType]
        }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else { return }

        do {
            try ensureRuntimeDirectoryExists()
        } catch {
            CotabbyLogger.models.error(
                "Failed to ensure runtime directory before import: \(error.localizedDescription)",
                metadata: ["directory": .string(runtimeDirectoryURL.path)]
            )
            return
        }

        // Copy files off the main thread so multi-gigabyte GGUFs don't freeze the UI.
        let sourceURLs = panel.urls
        let destinationDirectory = runtimeDirectoryURL
        Task.detached {
            let fileManager = FileManager.default
            for sourceURL in sourceURLs {
                let destinationURL = destinationDirectory.appendingPathComponent(
                    sourceURL.lastPathComponent, isDirectory: false
                )
                if fileManager.fileExists(atPath: destinationURL.path) { continue }
                do {
                    try fileManager.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    CotabbyLogger.models.error(
                        "Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)",
                        metadata: [
                            "source": .string(sourceURL.path),
                            "destination": .string(destinationURL.path)
                        ]
                    )
                }
            }
            await MainActor.run { [weak self] in
                self?.refreshModelStates()
                self?.onModelDirectoryChanged?()
            }
        }
    }

    /// Returns `true` only when the model lives in Cotabby's user-writable model directory.
    func canDeleteModel(filename: String) -> Bool {
        FileManager.default.fileExists(atPath: modelFileURL(filename: filename).path)
    }

    /// Removes one model from the user-managed runtime directory.
    func deleteModel(filename: String) {
        let targetURL = modelFileURL(filename: filename)

        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return
        }

        do {
            try FileManager.default.removeItem(at: targetURL)
            refreshModelStates()
            onModelDirectoryChanged?()
        } catch {
            CotabbyLogger.models.error("Failed to delete model \(filename): \(error.localizedDescription)")
        }
    }

    private func performDownload(_ model: DownloadableRuntimeModel) async {
        defer {
            downloadTasks[model.filename] = nil
        }

        do {
            try await performSingleFileDownload(model, url: model.downloadURL)

            CotabbyLogger.models.info("Download complete for \(model.filename)")
            modelStates[model.filename] = .downloaded
            onModelDirectoryChanged?()
        } catch {
            if DownloadOutcomeClassifier.isUserCancellation(error) {
                CotabbyLogger.models.info("Download cancelled by user for \(model.filename)")
                modelStates[model.filename] = isInstalled(model: model) ? .downloaded : .idle
            } else {
                CotabbyLogger.models.error("Download failed for \(model.filename): \(error.localizedDescription)")
                modelStates[model.filename] = .failed(error.localizedDescription)
            }
        }
    }

    private func performSingleFileDownload(
        _ model: DownloadableRuntimeModel, url: URL
    ) async throws {
        try ensureRuntimeDirectoryExists()
        let destinationURL = modelFileURL(filename: model.filename)
        let delegate = ModelDownloadSessionDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.downloadTasks[model.filename] != nil else { return }
                self.modelStates[model.filename] = .downloading(progress: progress)
            }
        }
        let downloadResult = try await delegate.download(from: url)
        try Task.checkCancellation()
        try validate(response: downloadResult.response)

        let fileManager = FileManager.default
        let stagingURL = runtimeDirectoryURL.appendingPathComponent(
            "\(model.filename).staging-\(UUID().uuidString)",
            isDirectory: false
        )
        try fileManager.moveItem(at: downloadResult.temporaryURL, to: stagingURL)

        do {
            try ModelFileValidator.validateSize(
                of: stagingURL, expectedBytes: model.expectedSizeBytes
            )
            try ModelFileValidator.validateSHA256(
                of: stagingURL, expectedSHA256: model.sha256
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: stagingURL, to: destinationURL)
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
