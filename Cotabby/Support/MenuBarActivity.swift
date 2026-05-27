import Foundation

/// File overview:
/// Pure rule that collapses Cotabby's three independent "working" pipelines into a single menu-bar
/// busy signal.
///
/// Why this file exists:
/// The menu bar shows one indicator meaning "Cotabby is doing something" rather than three separate
/// per-pipeline states (runtime/model load, on-screen context OCR, completion generation). Keeping
/// the "what counts as busy" mapping here — separate from the debounce timing in
/// `MenuBarActivityModel` — makes the decision trivial to read and unit test, and the exhaustive
/// switches force a compile error if any pipeline adds a state we forgot to classify.
enum MenuBarActivity {
    /// `.debouncing` is deliberately excluded: it means "the user is still typing", not "Cotabby is
    /// working", and surfacing it would strobe the menu bar on every keystroke. The leading-edge
    /// delay in `MenuBarActivityModel` further hides any generation that finishes near-instantly.
    static func isBusy(
        runtime: RuntimeBootstrapState,
        completion: SuggestionDebugState,
        visual: VisualContextStatus
    ) -> Bool {
        isRuntimeBusy(runtime) || isCompletionBusy(completion) || isVisualBusy(visual)
    }

    private static func isRuntimeBusy(_ state: RuntimeBootstrapState) -> Bool {
        switch state {
        case .starting, .loading:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    private static func isCompletionBusy(_ state: SuggestionDebugState) -> Bool {
        switch state {
        case .generating:
            return true
        case .idle, .disabled, .debouncing, .ready, .failed:
            return false
        }
    }

    private static func isVisualBusy(_ status: VisualContextStatus) -> Bool {
        switch status {
        case .capturing, .extractingText, .summarizingText:
            return true
        case .idle, .ready, .unavailable, .failed:
            return false
        }
    }
}
