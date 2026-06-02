import Foundation

/// File overview:
/// The required-prefix admissibility rule for constrained decoding. Given a byte prefix the
/// completion must still produce, it decides whether a candidate token may be emitted and what
/// prefix remains afterward. This is the foundation for steering generation onto a known
/// continuation — finishing a specific partially-formed word, for example — without ever letting the
/// model emit bytes that diverge from the requirement.
///
/// The rule is byte-exact and deliberately trie-free: correctness needs only the two-way prefix
/// check below (the token completes the requirement, or is itself a step toward it). A trie over the
/// vocabulary would only speed the per-step lookup, never change the result, so it can be layered in
/// later as a pure optimization without touching this contract. Working in bytes (not Characters)
/// keeps the rule correct across token boundaries that split a multi-byte UTF-8 scalar.
enum RequiredPrefixConstraint {
    /// The outcome of testing one token against the remaining required prefix.
    enum Step: Equatable {
        /// The token satisfies the requirement: it either completes the remaining prefix, or the
        /// prefix was already empty. Nothing is required of later tokens in this branch.
        case satisfied
        /// The token is a strict prefix of the requirement; `remaining` is what later tokens must
        /// still produce.
        case advanced(remaining: [UInt8])
        /// The token diverges from the requirement and is inadmissible.
        case rejected
    }

    /// Tests `tokenBytes` against `remainingPrefix` and reports whether the token may be emitted and
    /// what prefix would remain afterward.
    ///
    /// - An empty `remainingPrefix` means the requirement is already met: every token is `satisfied`.
    /// - A token at least as long as the remaining prefix is admissible only if it *starts with* the
    ///   whole remaining prefix (it completes, and may extend past, the requirement).
    /// - A shorter token is admissible only if the remaining prefix *starts with* the token's bytes
    ///   (it is a step toward the requirement); the unconsumed tail is what remains.
    static func step(remainingPrefix: [UInt8], tokenBytes: [UInt8]) -> Step {
        guard !remainingPrefix.isEmpty else {
            return .satisfied
        }
        if tokenBytes.count >= remainingPrefix.count {
            return tokenBytes.starts(with: remainingPrefix) ? .satisfied : .rejected
        }
        guard remainingPrefix.starts(with: tokenBytes) else {
            return .rejected
        }
        return .advanced(remaining: Array(remainingPrefix.dropFirst(tokenBytes.count)))
    }

    /// Whether `tokenBytes` may be emitted next given `remainingPrefix`, ignoring the leftover. A thin
    /// predicate over `step` for callers (e.g. a greedy admissibility mask) that do not track the
    /// remainder themselves.
    static func admits(remainingPrefix: [UInt8], tokenBytes: [UInt8]) -> Bool {
        step(remainingPrefix: remainingPrefix, tokenBytes: tokenBytes) != .rejected
    }
}
