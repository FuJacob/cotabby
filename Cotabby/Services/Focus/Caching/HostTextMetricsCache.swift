import Foundation

/// Caches `HostTextMetrics` per focused element so the handful of bounds queries behind them run
/// once per field, not on every focus poll.
///
/// Two retry paths exist because hosts fail in two different ways:
/// - Chromium loads inline text boxes lazily: the first bounds query after focus returns an empty
///   rect and only later queries answer. An empty answer is retried a bounded number of times,
///   spaced out over successive polls, then given up on so a host that never answers costs
///   nothing more.
/// - A field focused while (nearly) empty has no text to measure a width sample from, yet its
///   line geometry may already be known. Caching that answer as final would pin the field to
///   "no sample" for the whole session, and the typeface match would never improve. A missing
///   sample is therefore re-measured when the caret has moved to a new offset where a sample
///   could exist, again a bounded number of times.
/// - A field with a single line so far has no line pitch to measure (there is no other line to
///   compare against). The pitch is re-measured once the caret has travelled far enough that the
///   text may have wrapped, a bounded number of times, so a ghost can wrap exactly once the host
///   has shown where its second line sits.
///
/// Same lifetime shape as `FieldStyleCache`: a reference type retained by the value-typed resolver.
@MainActor
final class HostTextMetricsCache {
    static let maximumAttempts = 6
    static let maximumSampleAttempts = 6
    static let maximumPitchAttempts = 12
    /// Caret travel (UTF-16 units) before a missing pitch is worth another look: a wrapped line is
    /// never shorter than this in a field wide enough to wrap at all.
    static let pitchRetryCaretDistance = 16
    static let retryInterval: TimeInterval = 0.25
    /// Shortest prefix the probe can measure a width from (see `HostTextMetricsProbe.widthSample`).
    static let minimumSampleCaret = 2

    /// Everything known about one field. Replaced whole when the key changes, so a new field never
    /// inherits another's metrics or spent retries.
    private struct Entry {
        /// Nil only before the first field.
        var key: String?
        var metrics: HostTextMetrics?
        /// Asks made while the host has answered nothing at all.
        var measureBudget = RetryBudget(maximumAttempts: HostTextMetricsCache.maximumAttempts)
        /// Re-measures for a missing width sample and for a missing line pitch.
        var sampleBudget = RetryBudget(maximumAttempts: HostTextMetricsCache.maximumSampleAttempts)
        var pitchBudget = RetryBudget(maximumAttempts: HostTextMetricsCache.maximumPitchAttempts)
        /// One pacing for all three: every one of them is the same probe of the same host.
        var pacing = RetryPacing(interval: HostTextMetricsCache.retryInterval)
        /// Where the caret was at the last attempt that could have produced each value.
        var lastSampleCaret: Int?
        var lastPitchCaret: Int?
    }

    private var entry = Entry()

    func metrics(
        forKey key: String,
        caretLocation: Int,
        now: Date = Date(),
        measure: () -> HostTextMetrics?
    ) -> HostTextMetrics? {
        if key != entry.key {
            entry = Entry(key: key)
        }
        if let metrics = entry.metrics {
            let retrySample = metrics.sampleText == nil && shouldRetrySample(caretLocation: caretLocation, now: now)
            // A paragraph's box stands in for a pitch until two lines give one (see
            // `HostTextMetrics.linePitchIsFromParagraphBox`), so it does not end the search.
            let retryPitch = (metrics.linePitch == nil || metrics.linePitchIsFromParagraphBox)
                && shouldRetryPitch(caretLocation: caretLocation, now: now)
            guard retrySample || retryPitch else {
                return metrics
            }
            if retrySample {
                entry.sampleBudget.spend()
                entry.lastSampleCaret = caretLocation
            }
            if retryPitch {
                entry.pitchBudget.spend()
                entry.lastPitchCaret = caretLocation
            }
            entry.pacing.recordAttempt(at: now)
            guard let remeasured = measure() else {
                return metrics
            }
            // Every answer only adds to what is known. WebKit answers no line for a caret at the
            // very end of the text, so a re-measure taken there must not drop the line box learned
            // at focus time, and a sample-less re-measure must not drop the sample.
            // A pitch measured between two lines is not given up for a paragraph's box read later
            // (a caret back on a paragraph's first line), which is only its whole-point stand-in.
            let keepsMeasuredPitch = metrics.linePitch != nil && !metrics.linePitchIsFromParagraphBox
                && remeasured.linePitchIsFromParagraphBox
            let keptPitchMetrics = keepsMeasuredPitch || remeasured.linePitch == nil ? metrics : remeasured
            let merged = HostTextMetrics(
                sampleText: remeasured.sampleText ?? metrics.sampleText,
                sampleWidth: remeasured.sampleText != nil ? remeasured.sampleWidth : metrics.sampleWidth,
                lineRect: remeasured.lineRect ?? metrics.lineRect,
                linePitch: keptPitchMetrics.linePitch,
                // The flags travel with whichever line box and pitch were kept.
                lineRectIsFromTextMarkers: remeasured.lineRect != nil
                    ? remeasured.lineRectIsFromTextMarkers : metrics.lineRectIsFromTextMarkers,
                linePitchIsFromParagraphBox: keptPitchMetrics.linePitchIsFromParagraphBox
            )
            entry.metrics = merged
            return merged
        }
        guard entry.measureBudget.hasAttemptsLeft, entry.pacing.allowsAttempt(at: now) else {
            return nil
        }
        entry.measureBudget.spend()
        entry.pacing.recordAttempt(at: now)
        entry.lastSampleCaret = caretLocation
        entry.lastPitchCaret = caretLocation
        let measured = measure()
        entry.metrics = measured
        return measured
    }

    private func shouldRetryPitch(caretLocation: Int, now: Date) -> Bool {
        entry.pitchBudget.hasAttemptsLeft
            && abs(caretLocation - (entry.lastPitchCaret ?? caretLocation)) >= Self.pitchRetryCaretDistance
            && entry.pacing.allowsAttempt(at: now)
    }

    private func shouldRetrySample(caretLocation: Int, now: Date) -> Bool {
        entry.sampleBudget.hasAttemptsLeft
            && caretLocation >= Self.minimumSampleCaret
            && caretLocation != entry.lastSampleCaret
            && entry.pacing.allowsAttempt(at: now)
    }

    // Value-typed storage only; see `FieldStyleCache` for why the deinit is nonisolated.
    nonisolated deinit {}
}
