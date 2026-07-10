import Foundation

/// Chooses the prediction debounce from the last observed generation latency.
///
/// A fixed debounce serves two masters badly: on fast hardware it adds avoidable delay before
/// every suggestion, and on slow hardware it lets keystrokes pile doomed generations onto a model
/// that cannot keep up (each cancel still costs a decode setup and teardown). Keying the debounce
/// to the most recent generation latency makes fast machines snappier and slow machines calmer,
/// with no configuration. The configured value remains the fallback until a first latency exists.
nonisolated enum DebouncePolicy {
    static func milliseconds(
        lastGenerationLatencyMilliseconds: Int?,
        fallback: Int,
        engine: SuggestionEngineKind = .llamaOpenSource
    ) -> Int {
        // An HTTP endpoint cannot reuse Cotabby's in-process KV cache, and cancelling a request does
        // not guarantee the remote server stops its tokenizer immediately. A trailing-edge pause
        // therefore saves more time than it costs: it collapses a typing burst into one useful
        // request instead of filling Ollama's queue with work that will be discarded.
        if engine == .openAICompatible {
            guard let last = lastGenerationLatencyMilliseconds, last > 0 else {
                return max(fallback, 180)
            }
            switch last {
            case ...300: return 100
            case ...700: return 150
            default: return 220
            }
        }

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
