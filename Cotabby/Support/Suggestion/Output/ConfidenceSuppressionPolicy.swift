import Foundation

/// File overview:
/// Decides whether a completion is too low-confidence to show, based on the model's own
/// per-token log-probabilities.
///
/// Why this file exists:
/// The guiding principle is that a suppressed completion beats a wrong one. The engine now reports
/// a per-token log-probability, so we can drop completions the model itself was unsure about
/// instead of showing a confident-looking guess. The policy is pure and isolated so the threshold
/// is easy to test and tune. A floor of negative infinity (the default) disables suppression, so
/// this is a no-op until a caller opts in by raising the floor.
nonisolated enum ConfidenceSuppressionPolicy {
    /// Suppress when the completion's average per-token log-probability is below `floor`.
    static func shouldSuppress(averageLogprob: Double, floor: Double) -> Bool {
        guard floor > -.infinity else {
            return false
        }
        return averageLogprob < floor
    }
}
