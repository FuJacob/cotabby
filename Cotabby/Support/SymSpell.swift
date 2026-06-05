import Foundation

/// File overview:
/// Self-contained Swift implementation of SymSpell (Wolf Garbe's Symmetric Delete spelling
/// correction, https://github.com/wolfgarbe/symspell). Given a frequency dictionary of correct
/// words it returns the most frequent word within a small edit distance of a query in roughly
/// constant time, by precomputing a "delete index": every dictionary word is reduced by up to
/// `maxDictionaryEditDistance` single-character deletions, and a query is matched by reducing it the
/// same way and intersecting. Two strings are within edit distance k iff one of their delete-sets
/// intersects, which is what makes lookup independent of dictionary size.
///
/// We use this as the *correction* source for inline autocorrect. Detection (is-this-a-typo) stays
/// with `NSSpellChecker` so proper nouns and the user's learned words are respected and a fixed
/// dictionary never mis-"corrects" a real name.
///
/// Ported in-repo (rather than added as a dependency) so it is reviewable and unit-tested. The
/// delete index is memory-heavy but small next to the app's llama runtime, and is built once off
/// the main thread (see `SymSpellCorrector`).
///
/// Attribution — this is a Swift port of SymSpell, used under the MIT License:
///
///   Copyright (c) 2022 Wolf Garbe (https://github.com/wolfgarbe/SymSpell)
///
///   Permission is hereby granted, free of charge, to any person obtaining a copy of this software
///   and associated documentation files (the "Software"), to deal in the Software without
///   restriction, including without limitation the rights to use, copy, modify, merge, publish,
///   distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
///   Software is furnished to do so, subject to the following conditions: The above copyright
///   notice and this permission notice shall be included in all copies or substantial portions of
///   the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
///
/// The bundled `frequency_dictionary_en_82_765.txt` also ships with SymSpell and is derived from
/// Google Books Ngram data (CC BY 3.0) and SCOWL.

struct SymSpellSuggestion: Equatable {
    let term: String
    let distance: Int
    let count: Int64
}

/// `nonisolated` so the index can be built and queried off the main actor (the project defaults to
/// `@MainActor` isolation). It is not `Sendable` on its own: `SymSpellCorrector` owns the only
/// instance and serializes the one-time build against later reads with a lock.
nonisolated final class SymSpell {
    let maxDictionaryEditDistance: Int
    let prefixLength: Int

    /// word -> frequency count. Doubles as the dictionary-membership set.
    private var words: [String: Int64] = [:]
    /// index -> word, so the delete buckets can store compact `Int32` indices rather than strings.
    private var wordsList: [String] = []
    /// FNV-1a hash of a delete-variant -> the dictionary word indices that produce it. Hash
    /// collisions are harmless: every candidate is verified with a real bounded edit-distance check,
    /// so a colliding entry is simply discarded.
    private var deletes: [Int: [Int32]] = [:]
    private var maxDictionaryWordLength = 0

    init(maxDictionaryEditDistance: Int = 2, prefixLength: Int = 7) {
        self.maxDictionaryEditDistance = maxDictionaryEditDistance
        self.prefixLength = prefixLength
    }

    var isEmpty: Bool { wordsList.isEmpty }
    var wordCount: Int { wordsList.count }

    // MARK: - Dictionary loading

    /// Parses `word<space-or-tab>count` lines (the SymSpell frequency-dictionary format). Malformed
    /// lines are skipped. Call once, off the main thread — building the index is the expensive part.
    func loadDictionary(contents: String) {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, let count = Int64(parts[1]) else { continue }
            createDictionaryEntry(key: String(parts[0]), count: count)
        }
    }

    func createDictionaryEntry(key: String, count: Int64) {
        guard count > 0, words[key] == nil else { return }
        words[key] = count
        let index = Int32(wordsList.count)
        wordsList.append(key)

        let chars = Array(key)
        if chars.count > maxDictionaryWordLength { maxDictionaryWordLength = chars.count }
        for delete in editsPrefix(chars) {
            deletes[Self.hash(delete), default: []].append(index)
        }
    }

    /// All delete-variants of a word's prefix (capped at `prefixLength`) down to
    /// `maxDictionaryEditDistance`, plus the empty string for words short enough to delete entirely.
    private func editsPrefix(_ key: [Character]) -> Set<String> {
        var result = Set<String>()
        if key.count <= maxDictionaryEditDistance {
            result.insert("")
        }
        let prefix = key.count > prefixLength ? Array(key.prefix(prefixLength)) : key
        result.insert(String(prefix))
        edits(prefix, editDistance: 0, into: &result)
        return result
    }

    private func edits(_ word: [Character], editDistance: Int, into result: inout Set<String>) {
        let nextDistance = editDistance + 1
        guard word.count > 1 else { return }
        for index in word.indices {
            var deleted = word
            deleted.remove(at: index)
            if result.insert(String(deleted)).inserted, nextDistance < maxDictionaryEditDistance {
                edits(deleted, editDistance: nextDistance, into: &result)
            }
        }
    }

    // MARK: - Lookup

    /// Returns dictionary words within `maxEditDistance` of `input`, sorted best-first (lowest edit
    /// distance, then highest frequency). For autocorrect we take the first element. An exact
    /// dictionary match short-circuits to distance 0.
    func lookup(_ input: String, maxEditDistance: Int? = nil) -> [SymSpellSuggestion] {
        let maxED = min(maxEditDistance ?? maxDictionaryEditDistance, maxDictionaryEditDistance)
        let inputChars = Array(input)
        let inputLen = inputChars.count

        // Too long to be within maxED of any dictionary word.
        if inputLen - maxED > maxDictionaryWordLength { return [] }

        if let count = words[input] {
            return [SymSpellSuggestion(term: input, distance: 0, count: count)]
        }
        if maxED == 0 { return [] }

        var suggestions: [SymSpellSuggestion] = []
        var consideredSuggestions = Set<String>([input])
        var consideredDeletes = Set<String>()

        let query = Query(input: input, chars: inputChars, maxED: maxED)
        let inputPrefixLen = min(inputLen, prefixLength)
        var candidates: [[Character]] = [Array(inputChars.prefix(inputPrefixLen))]
        var candidatePointer = 0

        while candidatePointer < candidates.count {
            let candidate = candidates[candidatePointer]
            candidatePointer += 1

            matchDictionaryWords(
                forCandidate: candidate,
                query: query,
                considered: &consideredSuggestions,
                into: &suggestions
            )

            // Enqueue the candidate's own deletes (the input side of the symmetric search), bounded
            // by the prefix window and the max edit distance.
            if inputPrefixLen - candidate.count < maxED, candidate.count <= prefixLength {
                enqueueDeletes(of: candidate, considered: &consideredDeletes, into: &candidates)
            }
        }

        if suggestions.count > 1 {
            suggestions.sort { lhs, rhs in
                lhs.distance != rhs.distance ? lhs.distance < rhs.distance : lhs.count > rhs.count
            }
        }
        return suggestions
    }

    /// The immutable per-lookup query, bundled so the helpers stay within the parameter-count rule.
    private struct Query {
        let input: String
        let chars: [Character]
        let maxED: Int
    }

    /// Verifies every dictionary word in `candidate`'s delete bucket with a real bounded edit-distance
    /// check and appends those within `query.maxED` to `suggestions`. Extracted from `lookup` to keep
    /// that function within the project's cyclomatic-complexity budget.
    private func matchDictionaryWords(
        forCandidate candidate: [Character],
        query: Query,
        considered: inout Set<String>,
        into suggestions: inout [SymSpellSuggestion]
    ) {
        guard let dictIndices = deletes[Self.hash(String(candidate))] else { return }
        for index in dictIndices {
            let suggestion = wordsList[Int(index)]
            if suggestion == query.input { continue }
            let suggestionChars = Array(suggestion)
            // Cheap length prune before the O(n*m) distance computation.
            if abs(suggestionChars.count - query.chars.count) > query.maxED { continue }
            if !considered.insert(suggestion).inserted { continue }

            let distance = Self.damerauOSA(query.chars, suggestionChars, maxDistance: query.maxED)
            if distance >= 0 {
                suggestions.append(
                    SymSpellSuggestion(term: suggestion, distance: distance, count: words[suggestion] ?? 0)
                )
            }
        }
    }

    private func enqueueDeletes(
        of candidate: [Character],
        considered: inout Set<String>,
        into candidates: inout [[Character]]
    ) {
        for index in candidate.indices {
            var deleted = candidate
            deleted.remove(at: index)
            if considered.insert(String(deleted)).inserted {
                candidates.append(deleted)
            }
        }
    }

    /// The single best correction for `input`, or nil when nothing is within `maxDictionaryEditDistance`.
    func bestSuggestion(for input: String) -> SymSpellSuggestion? {
        lookup(input).first
    }

    // MARK: - Edit distance

    /// Bounded Damerau optimal-string-alignment distance (allows adjacent transposition). Returns -1
    /// when the distance exceeds `maxDistance`, so callers can prune cheaply.
    static func damerauOSA(_ source: [Character], _ target: [Character], maxDistance: Int) -> Int {
        let sourceLen = source.count
        let targetLen = target.count
        if sourceLen == 0 { return targetLen <= maxDistance ? targetLen : -1 }
        if targetLen == 0 { return sourceLen <= maxDistance ? sourceLen : -1 }
        if abs(sourceLen - targetLen) > maxDistance { return -1 }

        var prevPrev = [Int](repeating: 0, count: targetLen + 1)
        var prev = [Int](repeating: 0, count: targetLen + 1)
        var curr = [Int](repeating: 0, count: targetLen + 1)
        for col in 0...targetLen { prev[col] = col }

        for row in 1...sourceLen {
            curr[0] = row
            var rowMin = curr[0]
            for col in 1...targetLen {
                let cost = source[row - 1] == target[col - 1] ? 0 : 1
                var value = min(prev[col] + 1, curr[col - 1] + 1, prev[col - 1] + cost)
                if row > 1, col > 1, source[row - 1] == target[col - 2], source[row - 2] == target[col - 1] {
                    value = min(value, prevPrev[col - 2] + cost)
                }
                curr[col] = value
                rowMin = min(rowMin, value)
            }
            // Every remaining row can only add to the running minimum, so once the whole row exceeds
            // the budget the final distance cannot come back under it.
            if rowMin > maxDistance { return -1 }
            swap(&prevPrev, &prev)
            swap(&prev, &curr)
        }

        let distance = prev[targetLen]
        return distance <= maxDistance ? distance : -1
    }

    // MARK: - Hashing

    /// FNV-1a over UTF-8. Deterministic within a run; the index is rebuilt each launch so we do not
    /// depend on a stable hash across processes.
    static func hash(_ string: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }
}
