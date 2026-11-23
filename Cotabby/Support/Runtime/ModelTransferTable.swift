import Foundation

/// The lifecycle of every model download, keyed by transfer ID (the source URL).
///
/// This is the single source of truth `ModelDownloadManager` publishes from. A transfer's stop
/// intent, its URLSession resume data, and its progress live inside the one phase where they mean
/// something, so combinations such as "resume data for an idle model" or "a pause request with
/// nothing running" cannot be represented. Every transition is a pure function of the table and
/// the installed-file facts the caller passes in, which keeps the rules testable without a
/// network, a subprocess, or a task.
struct ModelTransferTable: Equatable {
    struct Transfer: Equatable {
        /// Source metadata for the row. Nil for rows that only mirror what is on disk, which is
        /// what lets `refresh` drop a dynamic (non-catalog) row nothing can describe any more.
        var model: DownloadableRuntimeModel?
        var phase: Phase
    }

    enum Phase: Equatable {
        case running(Running)
        case paused(progress: Double?, resumeData: Data?)
        case failed(String)
        case downloaded
        case idle
    }

    struct Running: Equatable {
        var progress: Double?
        var speedFormatted: String?
        var etaFormatted: String?
        /// What the user asked this transfer to do while it was running.
        var stopIntent: DownloadStopIntent?
        /// URLSession resume data carried over from the pause this run resumed from.
        var resumeData: Data?
    }

    enum StartResult: Equatable {
        case alreadyRunning
        case alreadyInstalled
        /// Another source owns the destination filename; the row was marked failed.
        case blocked(by: DownloadableRuntimeModel)
        case started
    }

    enum Outcome: Equatable {
        case completed
        case paused(resumeData: Data?)
        case cancelled
        case failed(String)
    }

    private var transfers: [String: Transfer] = [:]

    // MARK: - Queries

    func displayState(for id: String) -> ModelDownloadState? {
        transfers[id].map { Self.displayState(for: $0.phase) }
    }

    func isRunning(_ id: String) -> Bool {
        running(id) != nil
    }

    func stopIntent(for id: String) -> DownloadStopIntent? {
        running(id)?.stopIntent
    }

    func resumeData(for id: String) -> Data? {
        running(id)?.resumeData
    }

    /// The runtime directory is a flat namespace. A second source may not claim a destination
    /// while the first source is running or paused; the user must cancel the retained transfer first.
    func conflictingTransfer(for model: DownloadableRuntimeModel) -> DownloadableRuntimeModel? {
        let destinationKey = Self.destinationKey(model.filename)
        for (id, transfer) in transfers where id != model.id {
            guard let other = transfer.model, Self.destinationKey(other.filename) == destinationKey else {
                continue
            }
            switch transfer.phase {
            case .running, .paused:
                return other
            case .failed, .downloaded, .idle:
                continue
            }
        }
        return nil
    }

    // MARK: - Transitions

    /// Starts or resumes a transfer. A paused transfer keeps its progress and resume data.
    mutating func start(_ model: DownloadableRuntimeModel, isInstalled: Bool) -> StartResult {
        let id = model.id
        guard !isRunning(id) else {
            return .alreadyRunning
        }
        if isInstalled {
            transfers[id] = Transfer(model: transfers[id]?.model, phase: .downloaded)
            return .alreadyInstalled
        }
        if let conflictingModel = conflictingTransfer(for: model) {
            transfers[id] = Transfer(model: model, phase: .failed(Self.conflictMessage(filename: model.filename)))
            return .blocked(by: conflictingModel)
        }

        var running = Running(progress: displayState(for: id)?.progressFraction)
        if case .paused(_, let resumeData) = transfers[id]?.phase {
            running.resumeData = resumeData
        }
        transfers[id] = Transfer(model: model, phase: .running(running))
        return .started
    }

    /// Records a pause request. Returns false when nothing is running, so the caller has no
    /// backend to signal. A cancel already in force is kept.
    mutating func requestPause(_ id: String) -> Bool {
        guard var running = running(id) else {
            return false
        }
        running.stopIntent = DownloadStopIntent.merging(running.stopIntent, with: .pause)
        setRunning(running, for: id)
        return true
    }

    /// Records a cancel request on a running transfer and drops its resume data. Returns false
    /// when nothing is running; the caller then settles the row with `cancelInactive`.
    mutating func requestCancel(_ id: String) -> Bool {
        guard var running = running(id) else {
            return false
        }
        running.stopIntent = .cancel
        running.resumeData = nil
        setRunning(running, for: id)
        return true
    }

    /// Cancels a paused, failed, or never-started transfer: there is no backend to wait for, so
    /// the row settles immediately to whatever is on disk.
    mutating func cancelInactive(_ model: DownloadableRuntimeModel, isInstalled: Bool) {
        settle(model.id, isInstalled: isInstalled)
    }

    /// Progress reports that arrive after the transfer left `.running` are dropped, so a late
    /// callback can never repaint a finished row as downloading.
    mutating func updateProgress(_ id: String, progress: Double?, speedFormatted: String? = nil, etaFormatted: String? = nil) {
        guard var running = running(id) else {
            return
        }
        running.progress = progress
        running.speedFormatted = speedFormatted
        running.etaFormatted = etaFormatted
        setRunning(running, for: id)
    }

    /// Ends a running transfer. `isInstalled` is only consulted for a cancel, where an older copy
    /// of the destination file may still be on disk.
    mutating func finish(_ id: String, _ outcome: Outcome, isInstalled: Bool) {
        guard let running = running(id) else {
            return
        }
        switch outcome {
        case .completed:
            transfers[id]?.phase = .downloaded
        case .paused(let resumeData):
            // A pause that produced no new resume data keeps the data this run started from.
            transfers[id]?.phase = .paused(
                progress: Self.displayState(for: .running(running)).progressFraction,
                resumeData: resumeData ?? running.resumeData
            )
        case .cancelled:
            settle(id, isInstalled: isInstalled)
        case .failed(let message):
            transfers[id]?.phase = .failed(message)
        }
    }

    /// Reconciles settled rows with what is on disk. Running and paused transfers are never
    /// touched, so a refresh during a download cannot drop its progress.
    mutating func refresh(catalog: [DownloadableRuntimeModel], isInstalled: (String) -> Bool) {
        refreshCatalogRows(catalog, isInstalled: isInstalled)
        refreshDynamicRows(excluding: Set(catalog.map(\.id)), isInstalled: isInstalled)
    }

    private mutating func refreshCatalogRows(_ catalog: [DownloadableRuntimeModel], isInstalled: (String) -> Bool) {
        for model in catalog {
            let phase = transfers[model.id]?.phase
            switch phase {
            case .running, .paused:
                continue
            case .failed, .downloaded, .idle, nil:
                break
            }
            if isInstalled(model.filename) {
                transfers[model.id] = Transfer(model: transfers[model.id]?.model, phase: .downloaded)
            } else if phase == .downloaded {
                transfers[model.id]?.phase = .idle
            }
        }
    }

    /// Hugging Face models are created dynamically rather than appearing in the curated catalog.
    /// Reconcile those rows too, or a deleted dynamic model stays stuck in `.downloaded`.
    private mutating func refreshDynamicRows(excluding catalogIDs: Set<String>, isInstalled: (String) -> Bool) {
        for (id, transfer) in transfers where !catalogIDs.contains(id) {
            guard let model = transfer.model else {
                transfers.removeValue(forKey: id)
                continue
            }
            switch transfer.phase {
            case .running, .paused:
                continue
            case .failed:
                if isInstalled(model.filename) {
                    transfers[id]?.phase = .downloaded
                }
            case .idle, .downloaded:
                if isInstalled(model.filename) {
                    transfers[id]?.phase = .downloaded
                } else {
                    transfers.removeValue(forKey: id)
                }
            }
        }
    }

    // MARK: - Helpers

    static func conflictMessage(filename: String) -> String {
        "Another source is already downloading \(filename). "
            + "Cancel that transfer before downloading this file."
    }

    private static func destinationKey(_ filename: String) -> String {
        filename.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func displayState(for phase: Phase) -> ModelDownloadState {
        switch phase {
        case .running(let running):
            return .downloading(
                progress: running.progress,
                speedFormatted: running.speedFormatted,
                etaFormatted: running.etaFormatted
            )
        case .paused(let progress, _):
            return .paused(progress: progress)
        case .failed(let message):
            return .failed(message)
        case .downloaded:
            return .downloaded
        case .idle:
            return .idle
        }
    }

    private func running(_ id: String) -> Running? {
        if case .running(let running) = transfers[id]?.phase {
            return running
        }
        return nil
    }

    private mutating func setRunning(_ running: Running, for id: String) {
        transfers[id]?.phase = .running(running)
    }

    /// A row with nothing left to resume shows what is on disk. An idle row forgets its source
    /// metadata so it stops counting as a tracked dynamic model.
    private mutating func settle(_ id: String, isInstalled: Bool) {
        if isInstalled {
            transfers[id] = Transfer(model: transfers[id]?.model, phase: .downloaded)
        } else {
            transfers[id] = Transfer(model: nil, phase: .idle)
        }
    }
}
