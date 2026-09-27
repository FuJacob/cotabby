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
    private var lastSessionIdentity: FocusedInputSessionIdentity?
    private var nextGeneration: UInt64 = 0

    /// Converts the latest focus snapshot into a stable context and bumps the generation when
    /// either the writing session or the text/selection signature changes.
    func materialize(from snapshot: FocusedInputSnapshot) -> FocusedInputContext {
        let signature = snapshot.contentSignature

        // Identical drafts in two chat tabs are different requests. Session identity includes
        // navigation but excludes volatile AX tokens, so a wrapper refresh alone stays harmless.
        if snapshot.sessionIdentity != lastSessionIdentity || signature != lastSignature {
            nextGeneration &+= 1
        }

        lastSessionIdentity = snapshot.sessionIdentity
        lastSignature = signature

        let context = FocusedInputContext(snapshot: snapshot, generation: nextGeneration)
        currentContext = context
        return context
    }

    /// Resets the generation baseline when the suggestion pipeline is fully disabled.
    func clear() {
        lastSignature = nil
        lastSessionIdentity = nil
        currentContext = nil
        nextGeneration &+= 1
    }
}
