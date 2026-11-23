import Foundation

/// Per-backend latency memory that sizes the next debounce (`DebouncePolicy`).
///
/// Latencies are kept per engine so a slow HTTP backend retains an appropriate debounce without
/// leaking that latency into the in-process engines when the user switches between them.
struct EngineLatencyTracker: Equatable {
    /// How many first-text samples the typical value is read from. Small on purpose: the debounce
    /// should follow a model that warmed up or slowed down within a few requests.
    static let firstTextSampleCount = 3

    /// Last completed round trip per backend, retained across keystrokes.
    private(set) var lastCompletionMilliseconds: [SuggestionEngineKind: Int] = [:]
    private var recentFirstTextMilliseconds: [SuggestionEngineKind: [Int]] = [:]
    private var firstTextRecordedWorkID: UInt64?

    mutating func recordCompletion(milliseconds: Int, engine: SuggestionEngineKind) {
        lastCompletionMilliseconds[engine] = milliseconds
    }

    /// Records the latency to a request's first streamed text: what starting a request costs once
    /// the KV prefix is warm. Only the first partial of each work item counts; later partials
    /// carry the same request's growing latency and would drag the sample toward completion time.
    mutating func recordFirstText(milliseconds: Int, engine: SuggestionEngineKind, workID: UInt64) {
        guard firstTextRecordedWorkID != workID else { return }
        firstTextRecordedWorkID = workID
        let samples = recentFirstTextMilliseconds[engine, default: []] + [milliseconds]
        recentFirstTextMilliseconds[engine] = Array(samples.suffix(Self.firstTextSampleCount))
    }

    /// The median of the recent first-text samples, so one cache miss (a context refresh
    /// re-decoding a whole section) cannot put the next keystroke behind the slow debounce tier.
    func typicalFirstTextMilliseconds(engine: SuggestionEngineKind) -> Int? {
        let recent = recentFirstTextMilliseconds[engine, default: []].sorted()
        return recent.isEmpty ? nil : recent[recent.count / 2]
    }
}
