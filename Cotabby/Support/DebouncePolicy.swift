import Foundation

/// Chooses the prediction debounce from the last observed generation latency.
///
/// A fixed debounce serves two masters badly: on fast hardware it adds avoidable delay before
/// every suggestion, and on slow hardware it lets keystrokes pile doomed generations onto a model
/// that cannot keep up (each cancel still costs a decode setup and teardown). Keying the debounce
/// to the most recent generation latency makes fast machines snappier and slow machines calmer,
/// with no configuration. The configured value remains the fallback until a first latency exists.
nonisolated enum DebouncePolicy {
    static func milliseconds(lastGenerationLatencyMilliseconds: Int?, fallback: Int) -> Int {
        guard let last = lastGenerationLatencyMilliseconds, last > 0 else {
            return fallback
        }
        switch last {
        case ...70: return 15
        case ...140: return 25
        default: return 55
        }
    }
}
