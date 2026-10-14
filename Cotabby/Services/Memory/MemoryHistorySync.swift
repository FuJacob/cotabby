import Combine
import Foundation
import Logging

/// File overview:
/// Feeds conversation memory from the message stores on this Mac (WhatsApp, Apple Mail, Outlook,
/// Teams, Calendar, a documents folder and the cloud drives).
///
/// Each source has a reader (`Services/Memory/Readers`) that opens its store read-only and returns
/// messages after a cursor, a page at a time, on a background task. This type runs those readers
/// and hands each page to `MemoryEngine.ingest`, which scrubs, encrypts, stores and (in the
/// background) indexes it. The protected stores need Full Disk Access, which Cotabby holds; nothing
/// is copied anywhere on the way.
///
/// When it runs: when a source is switched on or "Sync Now" is pressed, when memory starts, and then
/// every 15 minutes while the Mac is on AC power (reading tens of thousands of mails on battery
/// would cost more than a slightly older memory is worth). Built once by `CotabbyAppEnvironment`;
/// the Memory pane observes `readiness`, `syncing` and `lastOutcome`.
@MainActor
final class MemoryHistorySync: ObservableObject {
    /// Whether each source can be read right now (permission, files present).
    @Published private(set) var readiness: [String: MemorySourceReadiness] = [:]
    /// Sources being read right now.
    @Published private(set) var syncing: Set<String> = []
    /// One line per source about the last sync, for the pane.
    @Published private(set) var lastOutcome: [String: String] = [:]
    /// Whether Cotabby has Full Disk Access (nil until first checked). The protected sources need it.
    @Published private(set) var hasFullDiskAccess: Bool?

    private let readers: [String: any MemoryHistoryReading]
    private let engine: @MainActor () -> MemoryEngine?
    private let isOnACPower: @MainActor () -> Bool
    private var periodicTask: Task<Void, Never>?
    /// The sync in flight per source.
    private var runs: [String: SyncRun] = [:]

    nonisolated static let periodicInterval: UInt64 = 15 * 60
    /// Records read per page.
    nonisolated static let pageSize = 400
    /// The longest one source reads per sync run before the next source's turn.
    nonisolated static let runBudget: TimeInterval = 5 * 60

    init(
        readers: [any MemoryHistoryReading] = MemoryHistorySync.defaultReaders(),
        engine: @escaping @MainActor () -> MemoryEngine?,
        isOnACPower: @escaping @MainActor () -> Bool
    ) {
        self.readers = Dictionary(uniqueKeysWithValues: readers.map { ($0.sourceID, $0) })
        self.engine = engine
        self.isOnACPower = isOnACPower
    }

    // All stored state is safe to release from any thread (Combine publishers, closures, task
    // handles, values). A nonisolated deinit keeps teardown off the back-deployment main-actor
    // executor shim, which over-releases on macOS 26 (same as `SuggestionSettingsModel`).
    nonisolated deinit {}

    /// One reader per source on this Mac (the documents folder's reader is made per sync, from its
    /// settings). Built in typed steps: as one literal plus a mapped array it type-checks slowly.
    nonisolated static func defaultReaders() -> [any MemoryHistoryReading] {
        var readers: [any MemoryHistoryReading] = [
            WhatsAppHistoryReader(), AppleMailHistoryReader(), OutlookHistoryReader(), TeamsCacheReader(), CalendarHistoryReader()
        ]
        for drive in CloudDriveReader.all {
            readers.append(CloudDriveReader(drive: drive))
        }
        return readers
    }

    /// The reader for a source; the documents folder comes from the source's settings.
    private func reader(for sourceID: String) -> (any MemoryHistoryReading)? {
        if sourceID == DocumentsHistoryReader.id {
            guard let folder = engine()?.configuration.sources[sourceID]?.options["folder"], !folder.isEmpty else { return nil }
            return DocumentsHistoryReader(folder: folder)
        }
        return readers[sourceID]
    }

    // MARK: - Readiness

    /// Protected files and folders of memory's own sources, the ones Full Disk Access opens: Mail's
    /// index, WhatsApp's database, Outlook's and Teams' data folders. Nothing of an app memory does
    /// not read is touched. The system privacy database is deliberately not used: newer macOS
    /// versions protect it beyond Full Disk Access, so it reported "not granted" while the sources
    /// were readable.
    nonisolated static var fullDiskAccessProbePaths: [String] {
        let home = NSHomeDirectory()
        return [
            home + "/Library/Mail/V10/MailData/Envelope Index",
            WhatsAppHistoryReader.defaultDatabasePath,
            home + "/Library/Group Containers/UBF8T346G9.Office/Outlook",
            home + "/Library/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams"
        ]
    }

    /// True when any protected file opens, false when one exists but macOS refuses it, nil when none
    /// of them exist (nothing to test against). Each file is opened read-only and closed at once;
    /// nothing is read.
    nonisolated static func probeFullDiskAccess(paths: [String] = fullDiskAccessProbePaths) -> Bool? {
        var refused = false
        for path in paths {
            let descriptor = open(path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return true
            }
            if errno == EPERM || errno == EACCES { refused = true }
        }
        return refused ? false : nil
    }

    /// Re-checks Full Disk Access, and the sources' readiness when it changed (granting it in System
    /// Settings takes effect without restarting Cotabby).
    func checkFullDiskAccess() {
        let granted = Self.probeFullDiskAccess()
        guard granted != hasFullDiskAccess else { return }
        hasFullDiskAccess = granted
        refreshReadiness()
    }

    func refreshReadiness() {
        var readers = readers
        if let documents = reader(for: DocumentsHistoryReader.id) { readers[DocumentsHistoryReader.id] = documents }
        Task {
            let results = await Task.detached(priority: .utility) {
                readers.mapValues { $0.readiness() }
            }.value
            if readiness != results { readiness = results }
        }
    }

    // MARK: - Syncing

    /// Reads everything new from `sourceID` and stores it. Safe to call repeatedly: a sync already
    /// running for the source makes later calls no-ops.
    func sync(_ sourceID: String) async {
        guard runs[sourceID] == nil, let engine = engine(), let reader = reader(for: sourceID) else { return }
        let cancellation = SyncCancellation()
        let task = Task { await self.run(sourceID, engine: engine, reader: reader, cancellation: cancellation) }
        runs[sourceID] = SyncRun(cancellation: cancellation, task: task)
        syncing.insert(sourceID)
        await task.value
        if runs[sourceID]?.cancellation === cancellation {
            runs[sourceID] = nil
            syncing.remove(sourceID)
        }
    }

    /// Stops the sync of `sourceID` (every source when nil) and waits until it has finished, so
    /// what the caller deletes next cannot come back from a page read before. A stopped sync keeps
    /// the cursor of the last page it stored, never one past it.
    func cancelSync(_ sourceID: String? = nil) async {
        let cancelled = runs.filter { sourceID == nil || $0.key == sourceID }
        for (id, run) in cancelled {
            run.cancellation.cancel()
            runs[id] = nil
            syncing.remove(id)
        }
        for run in cancelled.values {
            await run.task.value
        }
    }

    private func run(
        _ sourceID: String, engine: MemoryEngine, reader: any MemoryHistoryReading, cancellation: SyncCancellation
    ) async {
        let started = Date()
        let retentionDays = engine.configuration.privacy.retentionDays
        do {
            // Detached so the reading runs off the main actor; it does not inherit cancellation,
            // which is why the loop checks `cancellation` between pages.
            let stored = try await Task.detached(priority: .utility) { () throws -> Int in
                var cursor = engine.cursor(source: sourceID)
                let since = retentionDays > 0 ? Date().addingTimeInterval(-Double(retentionDays) * 86_400) : nil
                var stored = 0
                var hasMore = true
                // One run reads for at most `runBudget`, then yields to the other sources; the next
                // round resumes at the saved cursor. A first pass over a large drive takes hours
                // (each online-only file is downloaded to be read) and must not hold up mail.
                let deadline = Date().addingTimeInterval(Self.runBudget)
                while hasMore, Date() < deadline, !cancellation.isCancelled {
                    let page = try reader.read(after: cursor, since: since, limit: Self.pageSize)
                    // A page read while the sync was being cancelled is dropped with its cursor.
                    guard !cancellation.isCancelled else { break }
                    hasMore = page.hasMore
                    cursor = page.nextCursor ?? cursor
                    // The cursor is saved with the page it ends, so an interrupted sync resumes at a
                    // page boundary and never skips messages.
                    stored += try engine.ingest(source: sourceID, records: page.records, cursor: page.nextCursor,
                                                completeConversations: page.completeConversations).stored
                }
                // Read through to the end: what the source no longer has (deleted documents) goes too.
                if !hasMore, !cancellation.isCancelled, let live = reader.liveConversationIDs() {
                    try engine.forget(source: sourceID, conversationsNotIn: live)
                }
                return stored
            }.value
            guard !cancellation.isCancelled else { return }
            lastOutcome[sourceID] = stored == 0 ? "Up to date" : "Added \(stored) messages"
            readiness[sourceID] = .ready
            CotabbyLogger.app.info("Memory sync finished", metadata: [
                "source": .string(sourceID),
                "stored": .stringConvertible(stored),
                "seconds": .stringConvertible(Int(Date().timeIntervalSince(started)))
            ])
        } catch let error as ReadOnlySQLiteDatabase.DatabaseError {
            readiness[sourceID] = error.readiness
            lastOutcome[sourceID] = error.localizedDescription
        } catch {
            lastOutcome[sourceID] = error.localizedDescription
            CotabbyLogger.app.warning("Memory sync failed: \(error.localizedDescription)", metadata: ["source": .string(sourceID)])
        }
    }

    // MARK: - Schedule

    /// Starts the periodic sync of the enabled sources.
    func startPeriodicSync() {
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let engine = self.engine(), self.isOnACPower() {
                    for source in engine.configuration.enabledSourceIDs {
                        await self.sync(source)
                    }
                }
                try? await Task.sleep(nanoseconds: Self.periodicInterval * 1_000_000_000)
            }
        }
    }

    /// Stops the schedule and any sync in flight (memory was switched off). Not awaited: the engine
    /// refuses writes once stopped, and a cancelled sync ends after the page it is reading.
    func stopPeriodicSync() {
        periodicTask?.cancel()
        periodicTask = nil
        Task { await cancelSync() }
    }
}

/// A sync in flight: its cancellation flag and the task to await.
private struct SyncRun {
    let cancellation: SyncCancellation
    let task: Task<Void, Never>
}

/// A cancellation flag the detached reading loop can check: detached tasks do not inherit the
/// caller's cancellation. Locked, so it is safe to read from any thread.
nonisolated final class SyncCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
