import Foundation

/// Decides whether a streamed cumulative partial may replace the currently rendered ghost text.
///
/// Streamed renders are monotonic by policy: a candidate must strictly extend what is already on
/// screen. Two real hazards motivate this rather than trusting arrival order. Partials hop from
/// the decode thread to the main actor as independent tasks, so a shorter, older cumulative can
/// land after a longer one; and the text normalizer runs on every cumulative snapshot, so its
/// output for a longer raw string is not guaranteed to extend its output for a shorter one (for
/// example when a boundary rule trims a trailing fragment). Dropping non-extensions costs nothing:
/// the next partial or the authoritative final result supersedes it.
enum StreamedGhostTextPolicy {
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
