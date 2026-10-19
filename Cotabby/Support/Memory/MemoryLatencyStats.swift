import Foundation

/// File overview:
/// A rolling record of how long a memory operation takes (a search, embedding a query), for the
/// Memory pane's performance figures.
///
/// It keeps only the last `capacity` samples, so the median and 95th percentile describe how memory
/// performs now, not averaged over a launch's slow first searches while the model was loading; and it
/// stays a small value that can travel inside `MemoryEngineStatus`. Pure and `Sendable`.
nonisolated struct MemoryLatencyStats: Equatable, Sendable {
    static let capacity = 100

    /// Milliseconds, oldest first, at most `capacity`.
    private(set) var samples: [Double] = []
    /// Every sample ever recorded, including those no longer kept.
    private(set) var total = 0

    mutating func record(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        samples.append(milliseconds)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        total += 1
    }

    var median: Double? { percentile(0.5) }
    var p95: Double? { percentile(0.95) }

    /// The nearest-rank percentile of the kept samples; nil before the first one.
    func percentile(_ fraction: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((Double(sorted.count - 1) * min(max(fraction, 0), 1)).rounded())
        return sorted[rank]
    }
}
