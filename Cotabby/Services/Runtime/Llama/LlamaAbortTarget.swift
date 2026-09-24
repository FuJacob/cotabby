import Foundation

/// File overview:
/// Which native sequence a cancellation may abort right now, and whether an abort reached it.
///
/// `LlamaRuntimeCore` decodes a prompt in one native call that Swift cancellation cannot
/// interrupt, so a superseded request is stopped mid-decode through the engine's per-sequence
/// abort flag (`cancelSequence`). That flag is set once and never cleared: a sequence it reached
/// refuses every later decode. The core keeps its one autocomplete sequence from request to
/// request to reuse the prompt's KV prefix, so an abort that lands on a sequence the core then
/// keeps kills the NEXT request at its first decode, before it samples a single token.
/// Measured 2026-09-10: the target stayed published through sampling, where cancellation is
/// already polled between tokens, and 98 of the 101 requests that died within five milliseconds
/// in an Obsidian typing run followed a request cancelled mid-sampling; three of eight typing
/// pauses showed no suggestion at all.
///
/// The rules this type holds:
///   - a sequence is published only for the prompt decode that may need interrupting, and
///     withdrawn as soon as that decode returns;
///   - `abort` reaches the published sequence and records that it did, under the same lock
///     `withdraw` takes, so once `withdraw` has returned no abort can reach that sequence, not
///     even after the engine recycles its slot for the next request;
///   - `withdraw` reports whether an abort reached the sequence, and the core then discards it
///     instead of keeping a flagged sequence for reuse.
///
/// Owned by `LlamaRuntimeCore` for its whole life. `abort` runs on whichever thread cancels a
/// generation's task; `publish` and `withdraw` run on the thread holding the core's autocomplete
/// lock. `@unchecked Sendable` because the lock, not the type system, guards the state.
nonisolated final class LlamaAbortTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var sequenceID: Int32 = -1
    private var reached = false

    /// Makes `sequenceID` the target of any abort until `withdraw`, starting a fresh record: an
    /// abort that reached a sequence published earlier says nothing about this one.
    func publish(_ sequenceID: Int32) {
        lock.lock()
        defer { lock.unlock() }
        self.sequenceID = sequenceID
        reached = false
    }

    /// Aborts the published sequence's native work through `cancel`, when one is published. The
    /// call is made holding the lock, so it happens entirely before or entirely after any
    /// `withdraw`, and the slot it names is never one the engine has since handed to another request.
    func abort(_ cancel: (Int32) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard sequenceID >= 0 else { return }
        cancel(sequenceID)
        reached = true
    }

    /// Ends the publication and says whether an abort reached the sequence during it.
    @discardableResult
    func withdraw() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasReached = reached
        sequenceID = -1
        reached = false
        return wasReached
    }
}
