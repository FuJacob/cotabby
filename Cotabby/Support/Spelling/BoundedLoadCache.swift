import Foundation

/// A small cache whose values are expensive to build and are loaded on demand, at most
/// `limit` of them kept, least recently used evicted first.
///
/// Each key is absent, loading, or ready, held as one slot so a key cannot be both loading and
/// ready and a finished or failed load cannot forget to clear its loading mark. The type is a
/// plain value with no locking or I/O: the owner (`SymSpellCorrector`) serializes access and runs
/// the loads this reports as needed.
nonisolated struct BoundedLoadCache<Key: Hashable, Value> {
    nonisolated private enum Slot {
        case loading
        case ready(value: Value, lastAccess: UInt64)
    }

    nonisolated enum Lookup {
        case ready(Value)
        /// Nothing is cached and no load is running; the caller must start one. The key is now
        /// marked loading, so later lookups do not start a second.
        case startLoad
        case loading
    }

    private let limit: Int
    private var slots: [Key: Slot] = [:]
    private var accessSequence: UInt64 = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Keys with a value ready to use, in no particular order.
    var readyKeys: [Key] {
        slots.compactMap { key, slot in
            if case .ready = slot { return key }
            return nil
        }
    }

    /// Returns the cached value and marks it most recently used, or reports whether the caller
    /// has to start loading it.
    mutating func lookup(_ key: Key) -> Lookup {
        switch slots[key] {
        case .ready(let value, _):
            accessSequence &+= 1
            slots[key] = .ready(value: value, lastAccess: accessSequence)
            return .ready(value)
        case .loading:
            return .loading
        case nil:
            slots[key] = .loading
            return .startLoad
        }
    }

    /// Stores a loaded value as the most recently used, evicting older ready values beyond the
    /// limit. Keys that are still loading hold no memory yet and are never evicted, so an eviction
    /// cannot orphan a load that is about to publish.
    mutating func publish(_ value: Value, for key: Key) {
        accessSequence &+= 1
        slots[key] = .ready(value: value, lastAccess: accessSequence)

        while true {
            let ready = slots.compactMap { candidate, slot -> (key: Key, lastAccess: UInt64)? in
                if case .ready(_, let lastAccess) = slot { return (candidate, lastAccess) }
                return nil
            }
            guard ready.count > limit, let leastRecentlyUsed = ready.min(by: { $0.lastAccess < $1.lastAccess }) else {
                return
            }
            slots[leastRecentlyUsed.key] = nil
        }
    }

    /// Clears a loading mark after a load that produced nothing, so a later lookup can retry. A
    /// value published for the same key in the meantime is kept.
    mutating func loadFailed(for key: Key) {
        if case .loading = slots[key] {
            slots[key] = nil
        }
    }
}
