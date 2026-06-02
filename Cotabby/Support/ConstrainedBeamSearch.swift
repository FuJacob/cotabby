import Foundation

/// File overview:
/// A deterministic multi-branch (beam) search over a model's next-token logits, used by the
/// constrained decoder to explore several short continuations at once and keep the highest-scoring
/// one instead of committing to a single greedy token at each step.
///
/// Why this file exists:
/// Greedy argmax can paint a completion into a corner: a locally-best token that leads nowhere good.
/// A small beam keeps the best few branches per step and scores whole continuations by cumulative
/// log-probability, which yields steadier short completions. The algorithm is written against the
/// `BeamDecodeStepping` protocol so the search can be unit-tested against an in-memory fake that
/// returns fixed logits per token path; the live llama adapter is a thin KV-sync wrapper supplied by
/// the runtime. Everything here is pure and deterministic given the stepping inputs.

/// The single operation a beam search needs from the model: the next-token logits for a branch's
/// token path (the tokens generated so far, beyond the prompt). The provider syncs its own KV state
/// to `generatedTokens` before reading and returns nil when logits are unavailable. Modeled as a
/// closure rather than a protocol so the live adapter can be an instance method on the runtime — the
/// inference engine is a noncopyable C++ type that cannot be stored in a separate object — while
/// tests pass a scripted closure.
typealias BeamLogitsProvider = (_ generatedTokens: [Int]) -> [Float]?

/// Tuning for one beam search. `beamWidth` is the number of live branches kept per step; `topK` bounds
/// the per-branch expansion pool; `noRepeatNgramSize` forbids re-emitting an n-gram already in a
/// branch (the same anti-loop guard the greedy decoder uses).
struct BeamSearchConfiguration: Equatable {
    let beamWidth: Int
    let maxTokens: Int
    let topK: Int
    let noRepeatNgramSize: Int

    init(beamWidth: Int, maxTokens: Int, topK: Int, noRepeatNgramSize: Int = 3) {
        self.beamWidth = max(1, beamWidth)
        self.maxTokens = max(0, maxTokens)
        self.topK = topK
        self.noRepeatNgramSize = noRepeatNgramSize
    }
}

/// One explored continuation: the committed token ids (beyond the prompt), their accumulated raw
/// UTF-8 bytes, and the cumulative log-probability of the path.
struct BeamCandidate: Equatable {
    let tokenIDs: [Int]
    let bytes: [UInt8]
    let cumulativeLogprob: Double

    /// Mean per-token log-probability; ranks completed branches so a short confident continuation is
    /// not unfairly beaten by a longer, lower-average one. An empty branch ranks last.
    var meanLogprob: Double {
        tokenIDs.isEmpty ? -.infinity : cumulativeLogprob / Double(tokenIDs.count)
    }

    /// The decoded text of the branch. Lossy on a partial trailing scalar (a final token may carry
    /// only part of a multi-byte character), which renders as U+FFFD rather than dropping the branch.
    var text: String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }
}

enum ConstrainedBeamSearch {
    /// Runs a best-first beam search and returns completed branches, best mean-logprob first. A branch
    /// completes on an end-of-generation token, a single-line newline (not emitted), a sentence
    /// boundary, the token budget, or when no admissible token remains. Pure given `stepping`.
    static func search(
        nextLogits: @escaping BeamLogitsProvider,
        profile: TokenProfile,
        configuration: BeamSearchConfiguration,
        isSingleLine: Bool
    ) -> [BeamCandidate] {
        Engine(
            nextLogits: nextLogits,
            profile: profile,
            configuration: configuration,
            isSingleLine: isSingleLine
        ).run()
    }
}

/// The mutable-free search context, holding the inputs so the per-step helpers stay small. A struct
/// rather than passing the same four values through every call.
private struct Engine {
    let nextLogits: BeamLogitsProvider
    let profile: TokenProfile
    let configuration: BeamSearchConfiguration
    let isSingleLine: Bool

    func run() -> [BeamCandidate] {
        var frontier: [BeamCandidate] = [BeamCandidate(tokenIDs: [], bytes: [], cumulativeLogprob: 0)]
        var completed: [BeamCandidate] = []

        for _ in 0 ..< configuration.maxTokens {
            guard !frontier.isEmpty else { break }
            var nextFrontier: [BeamCandidate] = []
            for branch in frontier {
                guard let logits = nextLogits(branch.tokenIDs) else {
                    completed.append(branch)
                    continue
                }
                expand(branch: branch, logits: logits, live: &nextFrontier, completed: &completed)
            }
            frontier = Self.prune(nextFrontier, to: configuration.beamWidth)
        }
        // Budget exhausted: surviving branches are valid completions too.
        completed.append(contentsOf: frontier)
        return completed
            .filter { !$0.tokenIDs.isEmpty }
            .sorted { $0.meanLogprob > $1.meanLogprob }
    }

    /// Expands one branch across its admissible tokens, routing branch-ending tokens (end-of-
    /// generation, single-line newline, sentence boundary) into `completed` and the rest into `live`.
    private func expand(
        branch: BeamCandidate,
        logits: [Float],
        live: inout [BeamCandidate],
        completed: inout [BeamCandidate]
    ) {
        let blocked = RepetitionGuard.blockedTokens(
            history: branch.tokenIDs,
            ngramSize: configuration.noRepeatNgramSize
        )
        let candidates = ConstrainedSampler.rankedAdmissibleTokens(
            logits: logits,
            profile: profile,
            admissibleTokenIDs: nil,
            topK: configuration.topK,
            blockedTokenIDs: blocked
        )
        for tokenID in candidates {
            if profile.isEndOfGeneration(tokenID) {
                completed.append(branch)
                continue
            }
            if isSingleLine, profile.isNewline(tokenID) {
                completed.append(branch)
                continue
            }
            let tokenBytes = profile.bytes(for: tokenID)
            let child = extend(branch, by: tokenID, tokenBytes: tokenBytes, logits: logits)
            if Self.completesSentence(child.bytes, lastTokenBytes: tokenBytes) {
                completed.append(child)
            } else {
                live.append(child)
            }
        }
    }

    private func extend(
        _ branch: BeamCandidate,
        by tokenID: Int,
        tokenBytes: [UInt8],
        logits: [Float]
    ) -> BeamCandidate {
        var bytes = branch.bytes
        bytes.append(contentsOf: tokenBytes)
        let logprob = ConstrainedSampler.logProb(ofTokenAt: tokenID, in: logits) ?? 0
        return BeamCandidate(
            tokenIDs: branch.tokenIDs + [tokenID],
            bytes: bytes,
            cumulativeLogprob: branch.cumulativeLogprob + logprob
        )
    }

    /// Keeps the best `width` live branches by cumulative log-probability.
    private static func prune(_ branches: [BeamCandidate], to width: Int) -> [BeamCandidate] {
        guard branches.count > width else {
            return branches
        }
        return Array(branches.sorted { $0.cumulativeLogprob > $1.cumulativeLogprob }.prefix(width))
    }

    private static func completesSentence(_ bytes: [UInt8], lastTokenBytes: [UInt8]) -> Bool {
        guard lastTokenBytes.contains(where: { $0 == 0x2E || $0 == 0x21 || $0 == 0x3F }) else {
            return false
        }
        // swiftlint:disable:next optional_data_string_conversion
        return SentenceBoundaryClassifier.endsSentence(String(decoding: bytes, as: UTF8.self))
    }
}
