import AppKit
import Combine
import Foundation
import Logging
import UniformTypeIdentifiers

/// One model's current install/download lifecycle state in local storage.
enum ModelDownloadState: Equatable {
    case idle
    case downloading(progress: Double?, speedFormatted: String? = nil, etaFormatted: String? = nil)
    case paused(progress: Double?)
    case downloaded
    case failed(String)

    var statusText: String {
        switch self {
        case .idle:
            return "Not installed"
        case .downloading(let progress, let speed, let eta):
            if let progress {
                let percent = Int((progress * 100).rounded())
                if let speed, let eta {
                    return "Downloading \(percent)% (\(speed) · ETA \(eta))"
                } else if let speed {
                    return "Downloading \(percent)% (\(speed))"
                }
                return "Downloading \(percent)%"
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
        case .downloading(let progress, _, _):
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

/// Downloads model files on demand into a user-writable runtime directory.
/// This decouples app shipping from model shipping so model updates do not require app updates.
///
/// Uses `aria2c` for segmented, resumable transfers when available and falls back to URLSession.
@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var modelStates: [String: ModelDownloadState] = [:]

    var onModelDirectoryChanged: (() -> Void)?

    private let runtimeDirectoryURL: URL
    private var runtimeSearchDirectories: [URL]
    /// GGUF filenames discovered across every search directory, recomputed whenever the search set
    /// or on-disk contents change. Cached so the per-catalog-model install check in
    /// `refreshModelStates` does not re-walk the (recursively scanned) directories once per model.
    private var installedModelFilenames: Set<String> = []
    private var downloadTasks: [String: Task<Void, Never>] = [:]
    /// Metadata retained for dynamic Hugging Face rows after their task finishes. Transfer state is
    /// keyed by source URL rather than destination filename so equal leaf names never alias.
    private var trackedModelsByID: [String: DownloadableRuntimeModel] = [:]
    private var activeAria2Services: [String: Aria2DownloadService] = [:]
    private var activeSessionDelegates: [String: ModelDownloadSessionDelegate] = [:]
    private var urlSessionResumeDataByID: [String: Data] = [:]

    private enum RequestedOutcome: Equatable {
        case paused
        case cancelled
    }
    private var requestedOutcomes: [String: RequestedOutcome] = [:]

    init(runtimeDirectoryURL: URL? = nil) {
        let primaryDirectoryURL =
            runtimeDirectoryURL ?? BundledRuntimeLocator.userRuntimeDirectoryURL()
        self.runtimeDirectoryURL = primaryDirectoryURL
        runtimeSearchDirectories = Self.resolveSearchDirectories(primary: primaryDirectoryURL)

        refreshModelStates()
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
        modelStates[model.id] ?? (isInstalled(model: model) ? .downloaded : .idle)
    }

    /// Re-reads installed models from all active search directories and updates `@Published` state.
    /// Preserves in-flight `.downloading` and `.paused` states so a refresh during transfer never drops the progress bar.
    func refreshModelStates() {
        recomputeInstalledModelFilenames()
        refreshCatalogModelStates()
        refreshDynamicModelStates(excluding: Set(models.map(\.id)))
    }

    private func refreshCatalogModelStates() {
        for model in models {
            let currentState = modelStates[model.id]
            if case .downloading = currentState {
                continue
            }
            if case .paused = currentState {
                continue
            }

            if isInstalled(model: model) {
                modelStates[model.id] = .downloaded
            } else if currentState == .downloaded {
                modelStates[model.id] = .idle
            }
        }
    }

    private func refreshDynamicModelStates(excluding catalogIDs: Set<String>) {
        // HuggingFace models are created dynamically rather than appearing in the curated catalog.
        // Reconcile those keys too, or a deleted dynamic model remains stuck in `.downloaded`.
        let dynamicIDs = modelStates.keys.filter { !catalogIDs.contains($0) }
        for downloadID in dynamicIDs {
            guard let model = trackedModelsByID[downloadID] else {
                modelStates.removeValue(forKey: downloadID)
                continue
            }

            switch modelStates[downloadID] {
            case .downloading, .paused:
                continue
            case .failed:
                if isInstalled(model: model) {
                    modelStates[downloadID] = .downloaded
                }
            case .idle, .downloaded, nil:
                if isInstalled(model: model) {
                    modelStates[downloadID] = .downloaded
                } else {
                    modelStates.removeValue(forKey: downloadID)
                    trackedModelsByID.removeValue(forKey: downloadID)
                }
            }
        }
    }

    /// True when any configured directory holds a file matching `filename` or any known alias.
    func isModelInstalled(filename: String) -> Bool {
        isInstalled(filename: filename)
    }

    /// The flat model directory intentionally treats a destination filename as installed once.
    /// Transfer identity remains source-specific, but Cotabby never silently replaces an installed
    /// same-name model from another repository.
    func isModelInstalled(_ model: DownloadableRuntimeModel) -> Bool {
        isInstalled(model: model)
    }

    /// Returns the active downloaded model options from the primary directory.
    func installedModelOptions() -> [RuntimeModelOption] {
        let discovered = BundledRuntimeLocator.discoverGGUFModelURLs(in: runtimeDirectoryURL)
        return discovered.map {
            RuntimeModelOption(
                filename: $0.lastPathComponent,
                url: $0
            )
        }.sorted { $0.displayName < $1.displayName }
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

    /// Deletes a downloaded model file from the primary runtime directory.
    func deleteModel(_ model: RuntimeModelOption) throws {
        deleteModel(filename: model.filename)
    }

    func download(_ model: DownloadableRuntimeModel) {
        let downloadID = model.id
        guard downloadTasks[downloadID] == nil else {
            CotabbyLogger.models.debug("Download already in progress for \(model.filename)")
            return
        }

        if isInstalled(model: model) {
            CotabbyLogger.models.debug("Model \(model.filename) already installed, skipping download")
            modelStates[downloadID] = .downloaded
            return
        }

        trackedModelsByID[downloadID] = model
        if let conflictingModel = conflictingTransfer(for: model) {
            modelStates[downloadID] = .failed(
                "Another source is already downloading \(model.filename). "
                    + "Cancel that transfer before downloading this file."
            )
            CotabbyLogger.models.info(
                "Blocked a conflicting model download",
                metadata: [
                    "active_source": .string(conflictingModel.downloadURL.absoluteString),
                    "destination": .string(model.filename)
                ]
            )
            return
        }

        requestedOutcomes.removeValue(forKey: downloadID)
        let initialProgress = modelStates[downloadID]?.progressFraction
        CotabbyLogger.models.info("Starting download for \(model.filename)")
        modelStates[downloadID] = .downloading(progress: initialProgress)
        let task = Task { [weak self] in
            guard let self else {
                return
            }

            await self.performDownload(model)
        }
        downloadTasks[downloadID] = task
    }

    /// Pauses an in-flight download, saving partial metadata so it can be resumed later.
    func pause(_ model: DownloadableRuntimeModel) {
        let downloadID = model.id
        guard downloadTasks[downloadID] != nil else {
            return
        }
        requestedOutcomes[downloadID] = .paused
        if let aria2Service = activeAria2Services[downloadID] {
            aria2Service.pause()
        } else if let delegate = activeSessionDelegates[downloadID] {
            delegate.pause()
        } else if let task = downloadTasks[downloadID] {
            task.cancel()
        }
    }

    /// Resumes a previously paused download.
    func resume(_ model: DownloadableRuntimeModel) {
        download(model)
    }

    /// User-initiated cancel of an in-flight or paused model download.
    func cancel(_ model: DownloadableRuntimeModel) {
        let downloadID = model.id
        requestedOutcomes[downloadID] = .cancelled
        if let aria2Service = activeAria2Services[downloadID] {
            aria2Service.cancel()
        } else if let delegate = activeSessionDelegates[downloadID] {
            delegate.cancel()
        }

        urlSessionResumeDataByID.removeValue(forKey: downloadID)

        if let task = downloadTasks[downloadID] {
            // Let the backend stop before deleting its files. Removing a staging directory while
            // aria2c is still flushing its control file can recreate debris or corrupt the pause.
            task.cancel()
        } else {
            removeResumeArtifacts(for: model)
            requestedOutcomes.removeValue(forKey: downloadID)
            modelStates[downloadID] = isInstalled(model: model) ? .downloaded : .idle
            if modelStates[downloadID] == .idle {
                trackedModelsByID.removeValue(forKey: downloadID)
            }
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
        defer {
            downloadTasks[downloadID] = nil
            activeAria2Services.removeValue(forKey: downloadID)
            activeSessionDelegates.removeValue(forKey: downloadID)
            requestedOutcomes.removeValue(forKey: downloadID)
            switch modelStates[downloadID] {
            case .paused, .downloaded, .failed:
                break
            case .idle, .downloading, nil:
                trackedModelsByID.removeValue(forKey: downloadID)
            }
        }

        do {
            let aria2ExecutableURL = await resolveAria2Executable()

            if requestedOutcomes[downloadID] == .paused {
                throw Aria2DownloadError.paused
            }
            if requestedOutcomes[downloadID] == .cancelled || Task.isCancelled {
                throw CancellationError()
            }

            if let aria2ExecutableURL {
                try await performAria2Download(model, executableURL: aria2ExecutableURL)
            } else {
                try await performURLSessionDownload(model)
            }

            CotabbyLogger.models.info("Download complete for \(model.filename)")
            // Keep the discovered-filename cache in step with the new file on disk so an immediate
            // re-`download(_:)` of the same model is recognized as installed instead of re-fetched.
            recomputeInstalledModelFilenames()
            modelStates[downloadID] = .downloaded
            onModelDirectoryChanged?()
        } catch {
            if DownloadOutcomeClassifier.isUserPause(error) {
                CotabbyLogger.models.info("Download paused by user for \(model.filename)")
                let currentProgress = modelStates[downloadID]?.progressFraction
                modelStates[downloadID] = .paused(progress: currentProgress)
            } else if DownloadOutcomeClassifier.isUserCancellation(error) {
                CotabbyLogger.models.info("Download cancelled by user for \(model.filename)")
                removeResumeArtifacts(for: model)
                modelStates[downloadID] = isInstalled(model: model) ? .downloaded : .idle
            } else {
                CotabbyLogger.models.error("Download failed for \(model.filename): \(error.localizedDescription)")
                modelStates[downloadID] = .failed(error.localizedDescription)
            }
        }
    }

    /// Provisioning is an optimization, so a genuine setup failure selects URLSession. Task
    /// cancellation is also absorbed here long enough for `performDownload` to publish pause or
    /// cancel according to the manager's recorded user intent.
    private func resolveAria2Executable() async -> URL? {
        if let executableURL = Aria2Locator.executableURL() {
            return executableURL
        }

        do {
            return try await Aria2Provisioner.shared.provisionIfNeeded()
        } catch {
            if !Task.isCancelled {
                CotabbyLogger.models.debug(
                    "aria2 is unavailable; using URLSession: \(error.localizedDescription)"
                )
            }
            return nil
        }
    }

    private func performAria2Download(
        _ model: DownloadableRuntimeModel,
        executableURL: URL
    ) async throws {
        let downloadID = model.id
        try ensureRuntimeDirectoryExists()
        let destinationURL = modelFileURL(filename: model.filename)
        let stagingDir = aria2StagingDirectoryURL(for: model)

        let service = Aria2DownloadService { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.downloadTasks[downloadID] != nil else { return }
                self.modelStates[downloadID] = .downloading(
                    progress: progress.progressFraction,
                    speedFormatted: progress.speedFormatted,
                    etaFormatted: progress.etaFormatted
                )
            }
        }
        activeAria2Services[downloadID] = service

        let downloadedFile = try await service.download(
            from: model.downloadURL,
            filename: model.filename,
            stagingDirectory: stagingDir,
            executableURL: executableURL
        )

        let fileManager = FileManager.default
        do {
            try await Self.validateAndPromoteStagedFile(
                downloadedFile,
                to: destinationURL,
                // aria2 does not expose an independent response length; validate the catalog size once.
                declaredContentLength: nil,
                expectedSize: model.expectedSizeBytes,
                expectedSHA256: model.sha256
            )
            try? fileManager.removeItem(at: stagingDir)
        } catch {
            try? fileManager.removeItem(at: stagingDir)
            throw error
        }
    }

    private func performURLSessionDownload(_ model: DownloadableRuntimeModel) async throws {
        let downloadID = model.id
        try ensureRuntimeDirectoryExists()
        let destinationURL = modelFileURL(filename: model.filename)
        let delegate = ModelDownloadSessionDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.downloadTasks[downloadID] != nil else { return }
                self.modelStates[downloadID] = .downloading(progress: progress)
            }
        }
        activeSessionDelegates[downloadID] = delegate

        let resumeData = urlSessionResumeDataByID[downloadID]
        let downloadResult: ModelDownloadSessionDelegate.DownloadResult
        do {
            downloadResult = try await delegate.download(
                from: model.downloadURL,
                resumeData: resumeData
            )
        } catch let interruption as URLSessionDownloadInterruption {
            switch interruption {
            case .paused(let newResumeData):
                if let newResumeData {
                    urlSessionResumeDataByID[downloadID] = newResumeData
                }
                throw Aria2DownloadError.paused
            }
        } catch {
            // Invalid or stale resume data must not poison every subsequent Retry attempt.
            urlSessionResumeDataByID.removeValue(forKey: downloadID)
            throw error
        }
        let fileManager = FileManager.default
        let temporaryURL = downloadResult.temporaryURL

        urlSessionResumeDataByID.removeValue(forKey: downloadID)

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
    /// model before the replacement is committed (the old delete-then-move could leave nothing
    /// installed). `replaceItemAt` removes the staged file as part of the swap.
    private nonisolated static func validateAndPromoteStagedFile(
        _ stagingURL: URL,
        to destinationURL: URL,
        declaredContentLength: Int64?,
        expectedSize: Int64?,
        expectedSHA256: String?
    ) async throws {
        let validationTask = Task.detached(priority: .utility) {
            if let declaredContentLength {
                try ModelFileValidator.validateCompleteness(
                    of: stagingURL,
                    declaredContentLength: declaredContentLength
                )
            }
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

    /// Resolves an isolated, URL-unique staging directory for a model download to prevent cross-repo collisions.
    private func aria2StagingDirectoryURL(for model: DownloadableRuntimeModel) -> URL {
        Aria2StagingDirectoryResolver.directory(
            in: runtimeDirectoryURL,
            downloadURL: model.downloadURL,
            filename: model.filename
        )
    }

    /// Removes only the active source's resume state after its backend has stopped.
    /// Filename-only directories from development builds are intentionally left untouched because
    /// they contain no source identity and therefore cannot be deleted safely on this model's behalf.
    private func removeResumeArtifacts(for model: DownloadableRuntimeModel) {
        urlSessionResumeDataByID.removeValue(forKey: model.id)
        try? FileManager.default.removeItem(at: aria2StagingDirectoryURL(for: model))
    }

    private func isInstalled(model: DownloadableRuntimeModel) -> Bool {
        model.allKnownFilenames.contains(where: isInstalled(filename:))
    }

    /// The runtime directory is a flat namespace. A second source may not claim a destination
    /// while the first source is active or paused; the user must cancel the retained transfer first.
    private func conflictingTransfer(
        for model: DownloadableRuntimeModel
    ) -> DownloadableRuntimeModel? {
        let destinationKey = model.filename.precomposedStringWithCanonicalMapping.lowercased()
        for (downloadID, trackedModel) in trackedModelsByID where downloadID != model.id {
            let trackedDestinationKey = trackedModel.filename
                .precomposedStringWithCanonicalMapping
                .lowercased()
            guard trackedDestinationKey == destinationKey else {
                continue
            }
            if downloadTasks[downloadID] != nil || modelStates[downloadID]?.isPaused == true {
                return trackedModel
            }
        }
        return nil
    }

    private func isInstalled(filename: String) -> Bool {
        installedModelFilenames.contains(filename)
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
