import Foundation
import Logging

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
    /// The last observation traced for this field, so the debug trace records only polls where the
    /// caret's offset, position or text changed: a handful per keystroke, not twenty a second.
    private var lastTraced: CaretAdvanceSampler.Observation?

    /// Feeds one poll for the field `key` and returns the sampler's current sample.
    func sample(forKey key: String, observation: CaretAdvanceSampler.Observation) -> CaretAdvanceSampler.Sample? {
        if key != self.key {
            self.key = key
            sampler = CaretAdvanceSampler()
            lastTraced = nil
        }
        let sample = sampler.observe(observation)
        trace(observation, sample: sample)
        return sample
    }

    /// Debug-only record of each changed observation and the sample after it. It is the evidence
    /// for how a host orders its updates: whether the caret box moves before or after the
    /// keystroke's text is published decides how a width sample pairs characters with advances.
    private func trace(_ observation: CaretAdvanceSampler.Observation, sample: CaretAdvanceSampler.Sample?) {
        guard CotabbyLogger.focus.logLevel <= .debug else { return }
        if let lastTraced, lastTraced.documentCaret == observation.documentCaret,
           abs(lastTraced.caretX - observation.caretX) < 0.01, lastTraced.precedingText == observation.precedingText {
            return
        }
        lastTraced = observation
        CotabbyLogger.focus.debug(
            "Caret advance observed",
            metadata: [
                "stage": .string("caret-advance"),
                "doc": .stringConvertible(observation.documentCaret),
                "x": .stringConvertible(Double(observation.caretX)),
                "y": .stringConvertible(Double(observation.lineY)),
                "tail": .string(String(observation.precedingText.suffix(8))),
                "positioned": .stringConvertible(observation.isPositioned),
                "pending": .stringConvertible(sampler.pendingCharacterCount),
                "sample": .string(sample.map { String($0.text.suffix(24)) } ?? ""),
                "sample_w": .stringConvertible(Double(sample?.width ?? 0)),
                "sample_n": .stringConvertible(sample?.text.count ?? 0)
            ]
        )
    }

    // Value-typed storage only; see `FieldStyleCache` for why the deinit is nonisolated.
    nonisolated deinit {}
}
