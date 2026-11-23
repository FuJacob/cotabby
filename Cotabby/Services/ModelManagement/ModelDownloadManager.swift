import AppKit
import Combine
import Foundation
import Logging
import UniformTypeIdentifiers

/// One model's current install/download lifecycle state in local storage.
enum ModelDownloadState: Equatable {
    case idle
    case downloading(progress: Double?)
    case paused(progress: Double?)
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
        case .paused(let progress):
            if let progress {
                return "Paused (\(Int((progress * 100).rounded()))%)"
            }
            return "Paused"
        case .downloaded:
            return "Installed"
        case .failed(let message):
            return message
        }
    }

    var progressFraction: Double? {
        switch self {
        case .downloading(let progress):
            guard let progress else {
                return nil
            }
            return min(max(progress, 0), 1)
        case .paused(let progress):
            guard let progress else {
                return nil
            }
            return min(max(progress, 0), 1)
        case .idle, .downloaded, .failed:
            return nil
        }
    }

    var isDownloading: Bool {
        if case .downloading = self {
            return true
        }
        return false
    }

    var isPaused: Bool {
        if case .paused = self {
            return true
        }
        return false
    }
}

/// What is doing the work for a running transfer.
private enum LiveTransferBackend {
    /// The task is scheduled but has not opened its URLSession yet, so a stop request can only
    /// cancel the task.
    case starting
    case urlSession(ModelDownloadSessionDelegate)
}

/// Downloads model files on demand into a user-writable runtime directory.
/// This decouples app shipping from model shipping so model updates do not require app updates.
///
/// Transfers run in-process through URLSession, which also owns pause/resume through resume data.
/// Cotabby deliberately launches no external downloader: a helper process found on a user-writable
/// path would run as Cotabby's child and could act with its privacy grants.
@MainActor
final class ModelDownloadManager: ObservableObject {
    /// Every transfer's lifecycle, read by views through `state(for:)`. Transfer state is keyed by
    /// source URL rather than destination filename so equal leaf names from different repositories
    /// never alias.
    @Published private var transferTable = ModelTransferTable()

    var onModelDirectoryChanged: (() -> Void)?

    private let runtimeDirectoryURL: URL
    private var runtimeSearchDirectories: [URL]
    /// GGUF filenames discovered across every search directory, recomputed whenever the search set
    /// or on-disk contents change. Cached so the per-model install check in
    /// `refreshModelStates` does not re-walk the (recursively scanned) directories once per model.
    private var installedModelFilenames: Set<String> = []
    /// The task and backend of each transfer the table reports as running. An entry is added
    /// when a transfer starts and removed when it finishes; nothing else writes this dictionary.
    private var liveTransfers: [String: LiveTransfer] = [:]

    private struct LiveTransfer {
        let task: Task<Void, Never>
        var backend: LiveTransferBackend = .starting
    }

    init(runtimeDirectoryURL: URL? = nil) {
        let primaryDirectoryURL =
            runtimeDirectoryURL ?? BundledRuntimeLocator.userRuntimeDirectoryURL()
        self.runtimeDirectoryURL = primaryDirectoryURL
        runtimeSearchDirectories = Self.resolveSearchDirectories(primary: primaryDirectoryURL)

        refreshModelStates()

        // Off the main actor: removing a leftover multi-GB partial is filesystem work, and nothing
        // here depends on it finishing (discovery already skips hidden entries).
        Task.detached(priority: .utility) {
            ModelDownloadManager.removeLegacyAria2StagingDirectories(in: primaryDirectoryURL)
        }
    }

    /// Builds before aria2 was removed staged transfers in hidden `.aria2-staging-*` directories
    /// inside the model folder. Nothing resumes from them now, and a paused transfer could leave
    /// gigabytes there that Finder hides. The sweep is idempotent and costs one shallow listing, so it
    /// runs on every launch instead of tracking a one-time flag; a directory that could not be removed
    /// (for example, while the user has it open) is simply retried next launch. Only hidden top-level
    /// directories with that exact prefix are touched, never installed models.
    nonisolated static func removeLegacyAria2StagingDirectories(in runtimeDirectory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: runtimeDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for entry in entries where entry.lastPathComponent.hasPrefix(".aria2-staging-") {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            do {
                try fileManager.removeItem(at: entry)
            } catch {
                CotabbyLogger.models.debug(
                    "Could not remove a legacy aria2 staging directory: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Cotabby's own directory first (authoritative + download target), then any additive sources
    /// (the LM Studio library when enabled), deduped by normalized path.
    private static func resolveSearchDirectories(primary: URL) -> [URL] {
        var directories = [primary]
        for directoryURL in BundledRuntimeLocator.runtimeSearchDirectories() {
            let normalizedPath = directoryURL.standardizedFileURL.path
            if !directories.contains(where: { $0.standardizedFileURL.path == normalizedPath }) {
                directories.append(directoryURL)
            }
        }
        return directories
    }

    /// Reloads the set of search directories (e.g. after the LM Studio toggle changes in Settings).
    /// Updates the installed-filename cache and all model states to match the new search paths.
    func refreshSearchDirectories() {
        runtimeSearchDirectories = Self.resolveSearchDirectories(primary: runtimeDirectoryURL)
        refreshModelStates()
    }

    var models: [DownloadableRuntimeModel] {
        RuntimeModelCatalog.downloadableModels
    }

    func state(for model: DownloadableRuntimeModel) -> ModelDownloadState {
        transferTable.displayState(for: model.id) ?? (isModelInstalled(model) ? .downloaded : .idle)
    }

    /// Re-reads installed models from all active search directories and updates `@Published` state.
    /// Preserves in-flight `.downloading` and `.paused` states so a refresh during transfer never drops the progress bar.
    func refreshModelStates() {
        recomputeInstalledModelFilenames()
        transferTable.refresh(catalog: models, isInstalled: isModelInstalled(filename:))
    }

    /// True when any configured directory holds a file named `filename`. Answered from the
    /// discovered-filename cache, so it reflects disk as of the last refresh or completed download.
    func isModelInstalled(filename: String) -> Bool {
        installedModelFilenames.contains(filename)
    }

    /// The flat model directory intentionally treats a destination filename as installed once.
    /// Transfer identity remains source-specific, but Cotabby never silently replaces an installed
    /// same-name model from another repository.
    func isModelInstalled(_ model: DownloadableRuntimeModel) -> Bool {
        isModelInstalled(filename: model.filename)
    }

    /// The path shown in Settings and opened by "Open Folder". This is always Cotabby's own writable
    /// directory because that is where downloads and imports land; additive sources such as LM Studio
    /// are read-only and surfaced only through the model picker, not this control.
    var modelsDirectoryPath: String {
        runtimeDirectoryURL.path
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

    /// Starts a download, or resumes it when the model is paused.
    func download(_ model: DownloadableRuntimeModel) {
        let downloadID = model.id
        switch transferTable.start(model, isInstalled: isModelInstalled(model)) {
        case .alreadyRunning:
            CotabbyLogger.models.debug("Download already in progress for \(model.filename)")
        case .alreadyInstalled:
            CotabbyLogger.models.debug("Model \(model.filename) already installed, skipping download")
        case .blocked(let conflictingModel):
            CotabbyLogger.models.info(
                "Blocked a conflicting model download",
                metadata: [
                    "active_source": .string(conflictingModel.downloadURL.absoluteString),
                    "destination": .string(model.filename)
                ]
            )
        case .started:
            CotabbyLogger.models.info("Starting download for \(model.filename)")
            let task = Task { [weak self] in
                guard let self else {
                    return
                }

                await self.performDownload(model)
            }
            liveTransfers[downloadID] = LiveTransfer(task: task)
        }
    }

    /// Pauses an in-flight download, keeping its partial data so a later `download(_:)` resumes it.
    func pause(_ model: DownloadableRuntimeModel) {
        let downloadID = model.id
        guard transferTable.requestPause(downloadID), let live = liveTransfers[downloadID] else {
            return
        }
        switch live.backend {
        case .urlSession(let delegate):
            delegate.pause()
        case .starting:
            // No session exists to signal yet. `performDownload` checks the recorded intent before
            // opening one and publishes the pause instead of starting a transfer just to stop it.
            live.task.cancel()
        }
    }

    /// User-initiated cancel of an in-flight or paused model download.
    func cancel(_ model: DownloadableRuntimeModel) {
        let downloadID = model.id
        guard transferTable.requestCancel(downloadID), let live = liveTransfers[downloadID] else {
            transferTable.cancelInactive(model, isInstalled: isModelInstalled(model))
            return
        }

        switch live.backend {
        case .urlSession(let delegate):
            delegate.cancel()
        case .starting:
            break
        }
        // The running task settles the row once URLSession has actually stopped, so a late
        // completion cannot race the cancelled state.
        live.task.cancel()
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
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "gguf") ?? .data]
        panel.prompt = "Import"
        panel.message = "Choose .gguf models to import into Cotabby"

        guard panel.runModal() == .OK else {
            return
        }

        let sourceURLs = panel.urls
        guard !sourceURLs.isEmpty else {
            return
        }

        let destinationDirectory = runtimeDirectoryURL

        Task.detached {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(
                    at: destinationDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                CotabbyLogger.models.error(
                    "Failed to create the model directory: \(error.localizedDescription)",
                    metadata: ["destination": .string(destinationDirectory.path)]
                )
                return
            }

            var importedAnyModel = false
            for sourceURL in sourceURLs {
                let targetURL = destinationDirectory.appendingPathComponent(
                    sourceURL.lastPathComponent,
                    isDirectory: false
                )
                do {
                    // Resolve symlinks before comparing. A selected alias can otherwise point at
                    // the installed target and make a delete-then-copy sequence delete its source.
                    let canonicalSource = sourceURL.resolvingSymlinksInPath().standardizedFileURL
                    let canonicalTarget = targetURL.resolvingSymlinksInPath().standardizedFileURL
                    if canonicalSource == canonicalTarget {
                        continue
                    }

                    // Import is intentionally non-destructive. Replacing an installed multi-GB
                    // model without an explicit overwrite prompt risks losing a known-good file.
                    if fileManager.fileExists(atPath: targetURL.path) {
                        continue
                    }

                    let stagingURL = destinationDirectory.appendingPathComponent(
                        ".import-\(UUID().uuidString)",
                        isDirectory: false
                    )
                    defer { try? fileManager.removeItem(at: stagingURL) }
                    try fileManager.copyItem(at: sourceURL, to: stagingURL)

                    // Another import may have won the race while this copy was running.
                    guard !fileManager.fileExists(atPath: targetURL.path) else {
                        continue
                    }
                    try fileManager.moveItem(at: stagingURL, to: targetURL)
                    importedAnyModel = true
                    CotabbyLogger.models.info(
                        "Imported model: \(sourceURL.lastPathComponent)",
                        metadata: ["destination": .string(targetURL.path)]
                    )
                } catch {
                    CotabbyLogger.models.error(
                        "Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)",
                        metadata: [
                            "source": .string(sourceURL.path),
                            "destination": .string(targetURL.path)
                        ]
                    )
                }
            }

            guard importedAnyModel else {
                return
            }
            await MainActor.run { [weak self] in
                self?.refreshModelStates()
                self?.onModelDirectoryChanged?()
            }
        }
    }

    private func performDownload(_ model: DownloadableRuntimeModel) async {
        let downloadID = model.id
        let outcome: ModelTransferTable.Outcome

        do {
            // A pause or cancel that arrived before the session opened could only cancel the task.
            // Publish the user's recorded intent rather than starting a transfer just to stop it.
            switch transferTable.stopIntent(for: downloadID) {
            case .pause:
                throw DownloadInterruption.paused(resumeData: nil)
            case .cancel:
                throw DownloadInterruption.cancelled
            case nil:
                try Task.checkCancellation()
            }

            try await performURLSessionDownload(model)

            CotabbyLogger.models.info("Download complete for \(model.filename)")
            // Keep the discovered-filename cache in step with the new file on disk so an immediate
            // re-`download(_:)` of the same model is recognized as installed instead of re-fetched.
            recomputeInstalledModelFilenames()
            outcome = .completed
        } catch {
            switch DownloadOutcomeClassifier.classify(error) {
            case .paused(let resumeData):
                CotabbyLogger.models.info("Download paused by user for \(model.filename)")
                outcome = .paused(resumeData: resumeData)
            case .cancelled:
                CotabbyLogger.models.info("Download cancelled by user for \(model.filename)")
                outcome = .cancelled
            case .failed:
                CotabbyLogger.models.error("Download failed for \(model.filename): \(error.localizedDescription)")
                outcome = .failed(error.localizedDescription)
            }
        }

        liveTransfers[downloadID] = nil
        transferTable.finish(downloadID, outcome, isInstalled: isModelInstalled(model))
        if outcome == .completed {
            onModelDirectoryChanged?()
        }
    }

    private func performURLSessionDownload(_ model: DownloadableRuntimeModel) async throws {
        let downloadID = model.id
        try ensureRuntimeDirectoryExists()
        let destinationURL = modelFileURL(filename: model.filename)
        let delegate = ModelDownloadSessionDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.transferTable.updateProgress(downloadID, progress: progress)
            }
        }
        liveTransfers[downloadID]?.backend = .urlSession(delegate)

        let downloadResult = try await delegate.download(
            from: model.downloadURL,
            resumeData: transferTable.resumeData(for: downloadID)
        )
        let fileManager = FileManager.default
        let temporaryURL = downloadResult.temporaryURL

        do {
            try Task.checkCancellation()
            try validate(response: downloadResult.response)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        let stagingURL = runtimeDirectoryURL.appendingPathComponent(
            "\(model.filename).staging-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: temporaryURL, to: stagingURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        let responseLength = downloadResult.response.expectedContentLength
        let declaredContentLength = downloadResult.expectedFileSize > 0
            ? downloadResult.expectedFileSize
            : responseLength
        do {
            try await Self.validateAndPromoteStagedFile(
                stagingURL,
                to: destinationURL,
                declaredContentLength: declaredContentLength,
                expectedSize: model.expectedSizeBytes,
                expectedSHA256: model.sha256
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    /// Promotes a validated staged file into the install location. When a model already exists there,
    /// an atomic replace is used so a crash or error mid-promotion can never destroy the existing good
    /// model before the replacement is committed, as a delete-then-move could.
    /// `replaceItemAt` removes the staged file as part of the swap.
    private nonisolated static func validateAndPromoteStagedFile(
        _ stagingURL: URL,
        to destinationURL: URL,
        declaredContentLength: Int64,
        expectedSize: Int64?,
        expectedSHA256: String?
    ) async throws {
        let validationTask = Task.detached(priority: .utility) {
            try ModelFileValidator.validateCompleteness(
                of: stagingURL,
                declaredContentLength: declaredContentLength
            )
            try ModelFileValidator.validateSize(of: stagingURL, expectedBytes: expectedSize)
            try ModelFileValidator.validateSHA256(of: stagingURL, expectedSHA256: expectedSHA256)
            try Self.promoteStagedFile(at: stagingURL, to: destinationURL)
        }

        try await withTaskCancellationHandler {
            try await validationTask.value
        } onCancel: {
            validationTask.cancel()
        }
    }

    private nonisolated static func promoteStagedFile(
        at stagingURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw LlamaRuntimeError.unavailable(
                "Model download failed with status code \(httpResponse.statusCode)."
            )
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

    /// Rebuilds the discovered-filename cache by recursively scanning every search directory.
    private func recomputeInstalledModelFilenames() {
        var filenames: Set<String> = []
        for directoryURL in runtimeSearchDirectories {
            for modelURL in BundledRuntimeLocator.discoverGGUFModelURLs(in: directoryURL) {
                filenames.insert(modelURL.lastPathComponent)
            }
        }
        installedModelFilenames = filenames
    }
}
