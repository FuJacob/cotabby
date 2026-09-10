import Foundation

/// Keeps one `CaretAdvanceSampler` for the focused field across focus polls.
///
/// The sampler is a value type that has to remember the previous poll's caret; the resolver that
/// feeds it is a value type too, so the memory lives here, in a reference the resolver retains.
/// Same lifetime shape as `HostTextMetricsCache`: a new field key starts a fresh sampler, and only
/// the current field's sampler is kept.
@MainActor
final class CaretAdvanceSampleStore {
    private var key: String?
    private var sampler = CaretAdvanceSampler()

    /// Feeds one poll for the field `key` and returns the sampler's current sample.
    func sample(forKey key: String, observation: CaretAdvanceSampler.Observation) -> CaretAdvanceSampler.Sample? {
        if key != self.key {
            self.key = key
            sampler = CaretAdvanceSampler()
        }
        return sampler.observe(observation)
    }

    // Value-typed storage only; see `FieldStyleCache` for why the deinit is nonisolated.
    nonisolated deinit {}
}
