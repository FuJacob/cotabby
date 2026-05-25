import Foundation

/// File overview:
/// Assigns monotonically increasing generations to focused-input snapshots so asynchronous
/// suggestion work can prove whether a result is still fresh for the current field.
///
/// Assigns generations to focused input snapshots so stale completions can be rejected safely.
@MainActor
final class ContextBuffer {
    private(set) var currentContext: FocusedInputContext?

    private var lastSignature: String?
    private var lastProcessIdentifier: Int32?
    private var nextGeneration: UInt64 = 0

    /// Converts the latest focus snapshot into a stable context and bumps the generation when
    /// either the target process or the text/selection signature changes.
    func materialize(from snapshot: FocusedInputSnapshot) -> FocusedInputContext {
        let signature = snapshot.contentSignature

        // We bump the generation on process switch or content change. We intentionally use
        // `processIdentifier` instead of `elementIdentifier` here because Chrome recycles
        // AX node tokens between polls, making CFHash-based identity unstable. Intra-process
        // field switches are detected by the content signature changing.
        if snapshot.processIdentifier != lastProcessIdentifier || signature != lastSignature {
            nextGeneration &+= 1
        }

        lastProcessIdentifier = snapshot.processIdentifier
        lastSignature = signature

        let context = FocusedInputContext(snapshot: snapshot, generation: nextGeneration)
        currentContext = context
        return context
    }

    /// Resets the generation baseline when the suggestion pipeline is fully disabled.
    func clear() {
        lastSignature = nil
        lastProcessIdentifier = nil
        currentContext = nil
        nextGeneration &+= 1
    }
}
