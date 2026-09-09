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
///
/// Same lifetime shape as `FieldStyleCache`: a reference type retained by the value-typed resolver.
@MainActor
final class HostTextMetricsCache {
    static let maximumAttempts = 6
    static let maximumSampleAttempts = 6
    static let retryInterval: TimeInterval = 0.25
    /// Shortest prefix the probe can measure a width from (see `HostTextMetricsProbe.widthSample`).
    static let minimumSampleCaret = 2

    private var key: String?
    private var metrics: HostTextMetrics?
    private var attempts = 0
    private var sampleAttempts = 0
    private var lastSampleCaret: Int?
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
            lastSampleCaret = nil
            lastAttemptAt = nil
        }
        if let metrics {
            guard metrics.sampleText == nil, shouldRetrySample(caretLocation: caretLocation, now: now) else {
                return metrics
            }
            sampleAttempts += 1
            lastSampleCaret = caretLocation
            lastAttemptAt = now
            if let remeasured = measure(), remeasured.sampleText != nil {
                // WebKit answers no line for a caret at the very end of the text, so a re-measure
                // taken there would drop the line box learned at focus time; keep what is known.
                let merged = HostTextMetrics(
                    sampleText: remeasured.sampleText,
                    sampleWidth: remeasured.sampleWidth,
                    lineRect: remeasured.lineRect ?? metrics.lineRect,
                    linePitch: remeasured.linePitch ?? metrics.linePitch
                )
                self.metrics = merged
                return merged
            }
            return metrics
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
        let measured = measure()
        metrics = measured
        return measured
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
