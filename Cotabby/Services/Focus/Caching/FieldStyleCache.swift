import Foundation

/// Caches the resolved field text style per focused element so the `AXAttributedStringForRange`
/// read happens once per style run, not on every focus poll.
///
/// Reading per-character font/color is a synchronous cross-process Accessibility call. The focus
/// resolver runs many times per second while focus stays on one field, so re-reading every poll
/// would add avoidable main-thread latency on the hot path. Keying on element identity alone is not
/// enough, though: rich-text hosts (Notes, Mail, TextEdit, Pages) change font at the caret when the
/// user moves between runs or restyles text, and a style frozen at first focus then renders the
/// ghost in the wrong face. The cache therefore also tracks the *style run* the caret sits in
/// (`AXStyleRangeForIndex`, one extra call only when the caret leaves the known run) and the caret
/// box height (a free signal that the line's font changed on hosts without style ranges).
///
/// Chromium builds inline text boxes lazily, so its first attributed-string answer after focus is
/// empty and only later polls carry the font; caching that first nil forever left web fields with
/// no size. Empty answers are retried a bounded number of times, spaced over successive polls.
///
/// A reference type so it can carry state across the value-typed `FocusSnapshotResolver`'s
/// non-mutating `resolveSnapshot`, mirroring `DeepGeometryWalkThrottle`. The resolver is constructed
/// once and retained by `FocusTracker`.
@MainActor
final class FieldStyleCache {
    static let maximumAttempts = 6
    static let retryInterval: TimeInterval = 0.25

    /// What one cached answer was resolved for. A poll whose caret is still inside `styleRun` (or
    /// whose run lookup returns the same run) with an unchanged caret height reuses the answer.
    struct Probe: Equatable {
        let fieldKey: String
        /// Style run containing the character before the caret, in the host's own text
        /// coordinates; nil when the host exposes no style ranges.
        let styleRun: NSRange?
        /// The caret box height rounded to whole points.
        let caretHeightBucket: Int
    }

    private var probe: Probe?
    private var style: ResolvedFieldStyle?
    private var attempts = 0
    private var lastAttemptAt: Date?

    /// Returns the cached style for the caret's current style run, otherwise resolves and caches.
    ///
    /// - `caretLocation` is the caret offset in the host's coordinates; a cached style whose
    ///   `styleRun` contains the character before it is reused without any AX call.
    /// - `styleRun` is invoked only when the cached run does not cover the caret (or nothing is
    ///   cached); it may return nil for hosts without style ranges.
    /// - A nil result is retried on later calls (spaced by `retryInterval`) until
    ///   `maximumAttempts`, after which nil is cached for the probe.
    func style(
        forKey fieldKey: String,
        caretLocation: Int,
        caretHeight: CGFloat,
        now: Date = Date(),
        styleRun: () -> NSRange?,
        resolve: () -> ResolvedFieldStyle?
    ) -> ResolvedFieldStyle? {
        let heightBucket = Int(caretHeight.rounded())
        if let probe, probe.fieldKey == fieldKey, probe.caretHeightBucket == heightBucket,
           let cached = style, let run = probe.styleRun, Self.run(run, containsCaret: caretLocation) {
            return cached
        }

        let nextProbe = Probe(fieldKey: fieldKey, styleRun: styleRun(), caretHeightBucket: heightBucket)
        if nextProbe != probe {
            let sameFieldSameRun = probe?.fieldKey == fieldKey
                && probe?.caretHeightBucket == heightBucket
                && probe?.styleRun != nil
                && probe?.styleRun?.location == nextProbe.styleRun?.location
            probe = nextProbe
            if !sameFieldSameRun {
                style = nil
                attempts = 0
                lastAttemptAt = nil
            }
        }
        if let style {
            return style
        }
        guard attempts < Self.maximumAttempts else {
            return nil
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.retryInterval {
            return nil
        }
        attempts += 1
        lastAttemptAt = now
        let resolved = resolve()
        style = resolved
        return resolved
    }

    /// The character before the caret is the one the style was read from, so the caret sits inside
    /// the run when that character does.
    private static func run(_ run: NSRange, containsCaret caret: Int) -> Bool {
        let probedIndex = max(caret - 1, 0)
        return probedIndex >= run.location && probedIndex < run.location + max(run.length, 1)
    }

    // Stored state is plain value types, safe to release anywhere. The nonisolated deinit keeps
    // deallocation off the back-deployment main-actor executor shim, whose StopLookupScope
    // double-frees on macOS 26 (see InputSuppressionController). Production's single long-lived
    // instance never deallocates; test-scoped resolvers do.
    nonisolated deinit {}
}
