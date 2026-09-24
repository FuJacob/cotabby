import Foundation

/// Decides which streamed text can be shown now or retained for later acceptance.
///
/// Streamed renders are monotonic by policy: a candidate must strictly extend what is already on
/// screen. Two real hazards motivate this rather than trusting arrival order. Partials hop from
/// the decode thread to the main actor as independent tasks, so a shorter, older cumulative can
/// land after a longer one; and the text normalizer runs on every cumulative snapshot, so its
/// output for a longer raw string is not guaranteed to extend its output for a shorter one (for
/// example when a boundary rule trims a trailing fragment). Dropping non-extensions costs nothing:
/// the next partial or the authoritative final result supersedes it.
enum StreamedGhostTextPolicy {
    /// A hidden trailing fragment has not been offered as a word yet. If Tab stops generation,
    /// retaining `ag` from `world ag` would promote that fragment into the next acceptable word.
    /// Keep completed hidden words and their separators, but wait for a boundary before retaining
    /// the last token. Already visible characters are never removed: their presentation and
    /// acceptance have their own guards, and a buffer policy must not rewrite an existing offer.
    /// The coordinator calls this only for partials; a final result needs no boundary to be complete.
    static func completedBufferedPrediction(_ text: String, visibleCharacterCount: Int) -> String {
        let visibleCount = min(max(visibleCharacterCount, 0), text.count)
        guard visibleCount < text.count, let last = text.last,
              last.isLetter || last.isNumber || last == "_" || CaretWordContext.isConnector(last) else {
            return text
        }

        let token = String(text.reversed().prefix(while: { !$0.isWhitespace }).reversed())
        // A closing quote completes its quoted word. Apostrophes and hyphens elsewhere remain
        // lexical connectors, so `don't`, `state-of-the-art`, and a dangling `don'` still wait.
        if (last == "'" && token.first == "'") || (last == "’" && token.first == "‘") {
            return text
        }
        let completedCount = text.count - token.count
        return String(text.prefix(max(visibleCount, completedCount)))
    }

    static func isRenderableExtension(candidate: String, currentlyRendered: String?) -> Bool {
        guard !candidate.isEmpty else {
            return false
        }
        guard let currentlyRendered, !currentlyRendered.isEmpty else {
            return true
        }
        return candidate.count > currentlyRendered.count && candidate.hasPrefix(currentlyRendered)
    }
}
