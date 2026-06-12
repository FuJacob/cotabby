import Foundation

/// One remembered suggestion, anchored to the text that preceded it.
nonisolated struct SuggestionAnchor: Equatable {
    /// `FocusedInputContext.focusedInputIdentityKey` of the field the suggestion belonged to.
    let identityKey: UInt64
    /// The tail of `precedingText` at generation time (bounded; see `prefixTailLength`).
    let prefixTail: String
    /// The full normalized suggestion that was shown.
    let fullText: String
}

/// Bounded, string-only memory of recent suggestions so common editing moments can re-show a
/// known-good suggestion instantly instead of paying debounce plus a full model round-trip:
///
/// - **Backspace rollback**: deleting a typo restores the caret to a position a cached suggestion
///   already covered.
/// - **Type-through re-entry**: typing exactly the suggested characters after the session was
///   invalidated for an unrelated reason (focus bounce, shortcut) lands back inside it.
/// - **Field return**: coming back to a field whose text has not moved.
///
/// One match rule covers all three: the live preceding-text tail must equal a cached anchor's
/// tail plus the first `k` characters of its suggestion, for any `k` short of the whole
/// suggestion; the remainder is what is left to show. `k` strictly less than the full length
/// keeps a fully-consumed suggestion from re-offering its own tail right after acceptance.
///
/// Pure logic with an injected clock; entries expire so a stale suggestion cannot resurface after
/// the document changed elsewhere (the caller additionally re-checks display guards on restore).
nonisolated struct SuggestionAnchorCache {
    /// Characters of preceding-text tail stored per anchor. Long enough that an accidental
    /// cross-field or cross-paragraph collision is implausible; short enough to keep matching and
    /// memory trivial.
    static let prefixTailLength = 256
    static let capacity = 16
    static let maxEntryAge: TimeInterval = 180

    private struct Entry {
        let anchor: SuggestionAnchor
        let recordedAt: Date
    }

    private var entries: [Entry] = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Remembers one suggestion. The newest entry wins ties and duplicates are replaced, so a
    /// regenerated identical suggestion refreshes its expiry instead of crowding the cache.
    mutating func record(identityKey: UInt64, precedingText: String, fullText: String) {
        guard !fullText.isEmpty else { return }
        let anchor = SuggestionAnchor(
            identityKey: identityKey,
            prefixTail: Self.tail(of: precedingText),
            fullText: fullText
        )
        entries.removeAll { $0.anchor == anchor }
        entries.append(Entry(anchor: anchor, recordedAt: now()))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    private struct Match {
        let remainder: String
        let consumed: Int
        let recordedAt: Date

        func beats(_ other: Match?) -> Bool {
            guard let other else { return true }
            if consumed != other.consumed { return consumed > other.consumed }
            return recordedAt > other.recordedAt
        }
    }

    /// The unshown remainder of the freshest cached suggestion consistent with the live preceding
    /// text, or nil. Longest consumed prefix wins when several anchors match, so the restore
    /// resumes from exactly where the user is rather than re-showing already-typed words.
    mutating func remainder(identityKey: UInt64, precedingText: String) -> String? {
        pruneExpired()
        let liveTail = Self.tail(of: precedingText)

        var best: Match?
        for entry in entries.reversed() where entry.anchor.identityKey == identityKey {
            guard let consumed = Self.consumedPrefixLength(
                liveTail: liveTail,
                anchorTail: entry.anchor.prefixTail,
                fullText: entry.anchor.fullText
            ) else { continue }
            let match = Match(
                remainder: String(entry.anchor.fullText.dropFirst(consumed)),
                consumed: consumed,
                recordedAt: entry.recordedAt
            )
            if match.beats(best) {
                best = match
            }
        }
        return best?.remainder
    }

    mutating func removeAll() {
        entries.removeAll()
    }

    /// `k` such that liveTail == anchorTail + fullText.prefix(k) (tail-bounded comparison), with
    /// `0 <= k < fullText.count`; nil when the live text is not on the anchor's path.
    ///
    /// The character buffers are built once per entry and every candidate window is then an
    /// allocation-free slice comparison; the earlier form built a fresh
    /// `tail(anchorTail + fullText.prefix(k))` string for every k of every scanned entry, which
    /// is O(n) heap allocations per entry on a scan that visits up to the full cache.
    private static func consumedPrefixLength(
        liveTail: String,
        anchorTail: String,
        fullText: String
    ) -> Int? {
        let live = Array(liveTail)
        let composed = Array(anchorTail) + Array(fullText)
        let anchorCount = anchorTail.count

        for consumed in 0 ..< max(0, composed.count - anchorCount) {
            let end = anchorCount + consumed
            let start = max(0, end - prefixTailLength)
            guard end - start == live.count else { continue }
            if composed[start ..< end].elementsEqual(live) {
                return consumed
            }
        }
        return nil
    }

    private mutating func pruneExpired() {
        let cutoff = now().addingTimeInterval(-Self.maxEntryAge)
        entries.removeAll { $0.recordedAt < cutoff }
    }

    private static func tail(of text: String) -> String {
        String(text.suffix(prefixTailLength))
    }
}
