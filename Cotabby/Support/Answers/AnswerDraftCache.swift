import Foundation

/// File overview:
/// The drafts `AnswerCoordinator` has prepared, one per incoming message, and what they were drawn
/// from.
///
/// Why the stamp: a cached draft carries facts from memory as memory was when it was drafted.
/// Turning a source's "Use for answers" off, forgetting a source, excluding a person, or switching
/// memory off and on must not leave an older draft quoting what is no longer allowed. Each draft is
/// stored with the memory engine's identity, its data generation (which moves on every removal)
/// and its configuration; any difference empties the cache, so the next visit drafts again.
nonisolated struct AnswerDraftCache {
    /// What the cached drafts were drawn from.
    struct Stamp: Equatable, Sendable {
        let engine: UUID
        let dataGeneration: UInt64
        let configuration: MemoryConfiguration
    }

    private var stamp: Stamp?
    /// Per message key: an offer, or nil when there was nothing to offer.
    private var drafts: [String: AnswerOffer?] = [:]

    /// The prepared result for a message under `stamp`: `.some(offer)`, `.some(nil)` (nothing to
    /// offer), or nil (not prepared). A stamp other than the cache's empties it first; without a
    /// stamp (memory off) nothing is cached.
    mutating func lookup(_ key: String, stamp current: Stamp?) -> AnswerOffer?? {
        guard let current else {
            reset(to: nil)
            return nil
        }
        if current != stamp { reset(to: current) }
        return drafts[key]
    }

    /// Keeps a result prepared under `stamp`, unless memory moved on while it was prepared.
    mutating func store(_ offer: AnswerOffer?, for key: String, preparedUnder preparedStamp: Stamp?) {
        guard let preparedStamp, preparedStamp == stamp else { return }
        drafts[key] = .some(offer)
    }

    private mutating func reset(to newStamp: Stamp?) {
        drafts.removeAll()
        stamp = newStamp
    }
}
