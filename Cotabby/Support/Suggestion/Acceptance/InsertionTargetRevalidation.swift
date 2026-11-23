import Foundation

/// File overview:
/// Decides, immediately before Cotabby posts synthetic key events, whether keyboard focus still
/// belongs to the app whose field was validated for the insert.
///
/// Why this file exists:
/// `SuggestionInserter` posts its events at the HID tap, so they land wherever keyboard focus is
/// when they are delivered, not in the field Cotabby checked. That check reads a focus snapshot
/// that can be up to the coordinator's reuse window old (30 ms) on accept, and the emoji picker and
/// macros post their backspaces one run-loop turn after the commit key. If another app takes focus,
/// or a password field gains it, in that gap, the text or the deletes reach a field the user never
/// chose. The rule is pure so its edge cases (failed reads, system agents that own AX focus) are
/// testable without Accessibility; the inserter supplies the live observation.

/// The app whose field a caller validated before asking for an insert. Captured by the caller at
/// validation time, never re-read at post time: a snapshot read after the hop would already
/// describe whatever app took focus, and the check would pass against the wrong target.
nonisolated struct InsertionTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String

    init(processIdentifier: pid_t, bundleIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }

    init(snapshot: FocusedInputSnapshot) {
        self.init(processIdentifier: snapshot.processIdentifier, bundleIdentifier: snapshot.bundleIdentifier)
    }
}

/// What the inserter read right before posting. Kept to reads that cost at most one Accessibility
/// round trip, because this runs on the main actor inside the accept key's own tap callback.
nonisolated struct InsertionTargetObservation: Equatable, Sendable {
    /// True while some app holds secure event input, which AppKit's secure text field and the major
    /// browser engines turn on while a password field has keyboard focus. A local query, with no
    /// Accessibility round trip.
    let isSecureEventInputEnabled: Bool
    /// Owner of the system-wide focused element (the same query `FocusTracker` starts from), or nil
    /// when Accessibility gave no answer.
    let focusedProcessIdentifier: pid_t?
    let focusedBundleIdentifier: String?
    let frontmostProcessIdentifier: pid_t?
    let frontmostBundleIdentifier: String?
}

nonisolated enum InsertionTargetRevalidation {
    enum Verdict: Equatable {
        case proceed
        case abort(reason: String)
    }

    static func verdict(target: InsertionTarget, observation: InsertionTargetObservation) -> Verdict {
        if observation.isSecureEventInputEnabled {
            return .abort(reason: "Insertion skipped because a secure text field has keyboard focus.")
        }

        // No answer is not evidence that focus moved. It is the normal state for a Chromium field
        // reached only by hit-test (out-of-process iframes such as Gmail compose) and for a busy
        // host that hit the messaging timeout. In both, the validated snapshot is still the best
        // evidence available, and refusing would break accept in those hosts outright.
        guard let focusedProcessIdentifier = observation.focusedProcessIdentifier else {
            return .proceed
        }
        if focusedProcessIdentifier == target.processIdentifier {
            return .proceed
        }

        // A system agent (privacy prompt, notification banner) can own the system-wide focused
        // element while the frontmost app keeps receiving keystrokes. `FocusTracker` attributes
        // focus to the frontmost app in that case, so the same rule keeps the validated target.
        if observation.frontmostProcessIdentifier == target.processIdentifier,
           SystemUIFocusShadowPolicy.shouldPreferFrontmostApplication(
               owningBundleIdentifier: observation.focusedBundleIdentifier,
               frontmostBundleIdentifier: observation.frontmostBundleIdentifier
           ) {
            return .proceed
        }

        return .abort(reason: "Insertion skipped because keyboard focus moved to another app.")
    }
}
