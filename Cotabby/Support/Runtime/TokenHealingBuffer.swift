import Foundation

/// Separates a healed prompt suffix's replay from the new text a completion is allowed to show.
///
/// `LlamaRuntimeCore` creates one buffer per decode. The native sampler may choose a larger token
/// that begins with the exact bytes removed from the prompt; those bytes already belong to the
/// editor and must never appear in ghost text. Matching bytes here, rather than Swift characters,
/// also handles token pieces that split a Unicode scalar. After replay, incomplete UTF-8 stays
/// buffered until a complete string is available, so partial streaming never invents replacement
/// characters. The buffer owns no runtime pointers, tasks, or UI state and can be tested directly.
nonisolated struct TokenHealingBuffer {
    /// Bound the extra sampling work independently of the visible completion's token budget.
    static let maximumReplayTokens = 16
    /// A byte-fallback vocabulary can need one token per byte. Capping the candidate to the same
    /// count guarantees its replay fits even in that worst case; the runtime applies this policy
    /// before removing prompt tokens. The buffer itself can validate an arbitrary byte prefix.
    static let maximumHealedTokenBytes = maximumReplayTokens

    private var remainingReplay: ArraySlice<UInt8>
    private var visibleBytes: [UInt8] = []

    /// Latest complete, valid UTF-8 continuation, excluding every replayed byte.
    private(set) var text = ""
    /// The native prefix constraint is a boundary invariant. A mismatch permanently suppresses
    /// this decode, and lets the runtime stop sampling instead of exposing unrelated text.
    private(set) var hasReplayMismatch = false

    var replayComplete: Bool {
        !hasReplayMismatch && remainingReplay.isEmpty
    }

    /// A sampled token can add new bytes before those bytes form a complete Unicode scalar.
    /// Runtime token accounting uses this distinction so incomplete output still consumes its
    /// output-token budget instead of being mistaken for invisible prompt replay.
    var hasVisibleBytes: Bool {
        !visibleBytes.isEmpty
    }

    init(replayedPrefix: [UInt8]) {
        remainingReplay = replayedPrefix[...]
    }

    /// Returns cumulative visible text only when this piece adds a complete UTF-8 continuation.
    /// Returning nil during replay or a split scalar prevents redundant or malformed UI updates.
    mutating func append(tokenBytes: [UInt8]) -> String? {
        guard !hasReplayMismatch else { return nil }

        let replayCount = min(remainingReplay.count, tokenBytes.count)
        guard remainingReplay.prefix(replayCount).elementsEqual(tokenBytes.prefix(replayCount)) else {
            hasReplayMismatch = true
            visibleBytes.removeAll()
            text = ""
            return nil
        }
        remainingReplay = remainingReplay.dropFirst(replayCount)
        guard remainingReplay.isEmpty else { return nil }

        let newBytes = tokenBytes.dropFirst(replayCount)
        guard !newBytes.isEmpty else { return nil }
        visibleBytes.append(contentsOf: newBytes)

        // Lossy decoding would turn each unfinished token piece into U+FFFD. Keep the original
        // bytes until later pieces complete the scalar; an invalid byte sequence never publishes.
        guard let decoded = String(bytes: visibleBytes, encoding: .utf8) else { return nil }
        text = decoded
        return decoded
    }
}
