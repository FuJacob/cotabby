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

    private var key: String?
    private var metrics: HostTextMetrics?
    private var attempts = 0
    private var sampleAttempts = 0
    private var pitchAttempts = 0
    private var lastSampleCaret: Int?
    private var lastPitchCaret: Int?
    private var lastAttemptAt: Date?

    func metrics(
        forKey key: String,
        caretLocation: Int,
        now: Date = Date(),
        measure: () -> HostTextMetrics?
    ) -> HostTextMetrics? {
        if key != self.key {
            self.key = key
            metrics = nil
            attempts = 0
            sampleAttempts = 0
            pitchAttempts = 0
            lastSampleCaret = nil
            lastPitchCaret = nil
            lastAttemptAt = nil
        }
        if let metrics {
            let retrySample = metrics.sampleText == nil && shouldRetrySample(caretLocation: caretLocation, now: now)
            let retryPitch = metrics.linePitch == nil && shouldRetryPitch(caretLocation: caretLocation, now: now)
            guard retrySample || retryPitch else {
                return metrics
            }
            if retrySample {
                sampleAttempts += 1
                lastSampleCaret = caretLocation
            }
            if retryPitch {
                pitchAttempts += 1
                lastPitchCaret = caretLocation
            }
            lastAttemptAt = now
            guard let remeasured = measure() else {
                return metrics
            }
            // Every answer only adds to what is known. WebKit answers no line for a caret at the
            // very end of the text, so a re-measure taken there must not drop the line box learned
            // at focus time, and a sample-less re-measure must not drop the sample.
            let merged = HostTextMetrics(
                sampleText: remeasured.sampleText ?? metrics.sampleText,
                sampleWidth: remeasured.sampleText != nil ? remeasured.sampleWidth : metrics.sampleWidth,
                lineRect: remeasured.lineRect ?? metrics.lineRect,
                linePitch: remeasured.linePitch ?? metrics.linePitch,
                // The flag travels with whichever line box was kept.
                lineRectIsFromTextMarkers: remeasured.lineRect != nil
                    ? remeasured.lineRectIsFromTextMarkers : metrics.lineRectIsFromTextMarkers
            )
            self.metrics = merged
            return merged
        }
        guard attempts < Self.maximumAttempts else {
            return nil
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.retryInterval {
            return nil
        }
        attempts += 1
        lastAttemptAt = now
        lastSampleCaret = caretLocation
        lastPitchCaret = caretLocation
        let measured = measure()
        metrics = measured
        return measured
    }

    private func shouldRetryPitch(caretLocation: Int, now: Date) -> Bool {
        guard pitchAttempts < Self.maximumPitchAttempts,
              abs(caretLocation - (lastPitchCaret ?? caretLocation)) >= Self.pitchRetryCaretDistance
        else {
            return false
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.retryInterval {
            return false
        }
        return true
    }

    private func shouldRetrySample(caretLocation: Int, now: Date) -> Bool {
        guard sampleAttempts < Self.maximumSampleAttempts,
              caretLocation >= Self.minimumSampleCaret,
              caretLocation != lastSampleCaret
        else {
            return false
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.retryInterval {
            return false
        }
        return true
    }

    // Value-typed storage only; see `FieldStyleCache` for why the deinit is nonisolated.
    nonisolated deinit {}
}
