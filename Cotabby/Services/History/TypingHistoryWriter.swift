import Foundation

/// Serializes every write and delete of the typing-history archive, and drops writes that a
/// deletion has made stale.
///
/// Why this exists: saves run on background tasks with a snapshot of the records. Cancelling the
/// task that awaits a save does not stop a save that has already started, so without this a save
/// begun just before Delete All could finish afterwards, create a fresh Keychain key, and write the
/// deleted history back. Here, every operation takes one lock, so a delete waits for an in-flight
/// save, and each delete raises `minimumGeneration` so any save captured before it is skipped.
///
/// It is a lock rather than an actor because the termination flush must write synchronously on
/// the main thread; both paths share the same ordering rules.
nonisolated final class TypingHistoryWriter: @unchecked Sendable {
    private let vault: TypingHistoryVault
    private let lock = NSLock()
    /// Writes captured at an older generation than this are stale (a deletion happened since).
    private var minimumGeneration = 0
    /// Writes are numbered as they are captured, so an older snapshot finishing late cannot
    /// overwrite a newer one already on disk.
    private var lastWrittenSequence = 0

    init(vault: TypingHistoryVault) {
        self.vault = vault
    }

    /// Writes `records` unless a deletion or a newer write has made them stale.
    func save(_ records: [TypingHistoryRecord], generation: Int, sequence: Int) throws {
        try lock.withLock {
            guard generation >= minimumGeneration, sequence > lastWrittenSequence else { return }
            try vault.save(records)
            lastWrittenSequence = sequence
        }
    }

    /// Deletes the archive and its key, after any write already in progress, and marks every write
    /// captured before `generation` as stale.
    func destroy(generation: Int) throws {
        try lock.withLock {
            minimumGeneration = max(minimumGeneration, generation)
            try vault.destroy()
        }
    }
}
