import Foundation

/// File overview:
/// Per-token metadata used by constrained decoding: for every token id in a model's vocabulary it
/// records the token's raw UTF-8 bytes plus a few classification flags (control, end-of-generation,
/// whitespace-only, newline). Constrained sampling and prefix admissibility both read from this
/// table instead of querying a live engine.
///
/// Why this file exists:
/// Constrained decoding needs the *byte* shape of every candidate token (to test whether it can
/// continue a required prefix) and a way to drop tokens that should never be sampled as visible text
/// (control / structural tokens). A live tokenizer cannot be called from pure decision code without
/// dragging the runtime in, and it would not be deterministically testable. Building this profile
/// once from injected vocabulary data keeps the decoding rules pure: tests supply stub closures for
/// the bytes and flags, and the same inputs always yield the same verdicts. The builder takes
/// closures rather than concrete engine objects precisely so no runtime dependency leaks in.
struct TokenProfile {
    /// Classification flags for a single token, kept compact so the per-token table stays small even
    /// for large vocabularies.
    struct Entry {
        /// The token's raw UTF-8 bytes. Byte-level (not String) because admissibility against a
        /// partial-word prefix is a byte-prefix relationship: a token may encode only part of a
        /// multi-byte scalar, and Strings cannot represent that fragment.
        let bytes: [UInt8]
        /// A structural / control token (for example a chat or special marker) that must never be
        /// emitted as visible completion text.
        let isControl: Bool
        /// A token the engine treats as a stop / end-of-generation signal.
        let isEndOfGeneration: Bool
        /// The decoded bytes are non-empty and contain only whitespace.
        let isWhitespaceOnly: Bool
        /// The decoded bytes contain a line feed (`\n`).
        let isNewline: Bool
    }

    /// Indexed by token id; `entries[id]` is the metadata for token `id`.
    let entries: [Entry]

    /// The number of tokens described by this profile.
    var vocabSize: Int { entries.count }

    /// Builds a profile for `vocabSize` tokens by pulling each token's bytes and flags from the
    /// supplied closures. The closures are the only source of engine data, which is what keeps the
    /// type pure and testable: a runtime passes detokenize / control / EOG lookups, and a test passes
    /// stubs. Whitespace-only and newline are derived from the bytes here so callers cannot supply an
    /// inconsistent classification.
    static func build(
        vocabSize: Int,
        bytesFor: (Int) -> [UInt8],
        isControl: (Int) -> Bool,
        isEndOfGeneration: (Int) -> Bool
    ) -> TokenProfile {
        guard vocabSize > 0 else {
            return TokenProfile(entries: [])
        }
        var entries: [Entry] = []
        entries.reserveCapacity(vocabSize)
        for id in 0..<vocabSize {
            let bytes = bytesFor(id)
            entries.append(
                Entry(
                    bytes: bytes,
                    isControl: isControl(id),
                    isEndOfGeneration: isEndOfGeneration(id),
                    isWhitespaceOnly: Self.isWhitespaceOnly(bytes),
                    isNewline: bytes.contains(Self.lineFeed)
                )
            )
        }
        return TokenProfile(entries: entries)
    }

    /// The token's raw UTF-8 bytes, or an empty array for an out-of-range id. Returning empty rather
    /// than trapping keeps the decoding loop defensive against a stray id without a separate bounds
    /// dance at every call site.
    func bytes(for id: Int) -> [UInt8] {
        guard let entry = entry(for: id) else {
            return []
        }
        return entry.bytes
    }

    /// Whether `id` must be excluded from ordinary sampling. Control tokens are excluded so structural
    /// markers never surface as visible completion text. An out-of-range id is treated as excluded so
    /// it can never be selected by accident.
    func isExcluded(_ id: Int) -> Bool {
        guard let entry = entry(for: id) else {
            return true
        }
        return entry.isControl
    }

    /// Whether `id` is an end-of-generation token. False for an out-of-range id.
    func isEndOfGeneration(_ id: Int) -> Bool {
        entry(for: id)?.isEndOfGeneration ?? false
    }

    /// Whether `id` decodes to bytes containing a newline. False for an out-of-range id.
    func isNewline(_ id: Int) -> Bool {
        entry(for: id)?.isNewline ?? false
    }

    /// Whether `id` decodes to non-empty, whitespace-only bytes. False for an out-of-range id.
    func isWhitespaceOnly(_ id: Int) -> Bool {
        entry(for: id)?.isWhitespaceOnly ?? false
    }

    /// Whether `id` can continue the current word mid-stream: its first byte is an ASCII letter or
    /// digit, a common within-word mark (apostrophe or hyphen), or a non-ASCII lead byte (which starts
    /// a multi-byte letter or ideograph). Tokens that begin with whitespace, breaking punctuation, or a
    /// symbol are rejected, so a mid-word completion finishes the word instead of starting a new token.
    /// False for an out-of-range or empty (control) token.
    func continuesWordMidStream(_ id: Int) -> Bool {
        guard let bytes = entry(for: id)?.bytes, !bytes.isEmpty else {
            return false
        }
        // Inspect the first character with Unicode-aware classification: letters (including CJK and
        // other scripts) and digits continue a word, as do the two common within-word marks; whitespace,
        // punctuation, and symbols (ASCII or not, e.g. an em dash or arrow) do not. The lossy decode is
        // fine because only the first scalar is examined and a malformed lead decodes to U+FFFD, which
        // is not a letter, so it is rejected.
        // swiftlint:disable:next optional_data_string_conversion
        guard let first = String(decoding: bytes, as: UTF8.self).first else {
            return false
        }
        return first.isLetter || first.isNumber || first == "'" || first == "-"
    }

    private func entry(for id: Int) -> Entry? {
        guard id >= 0, id < entries.count else {
            return nil
        }
        return entries[id]
    }

    private static let lineFeed: UInt8 = 0x0A

    /// Non-empty and every byte is an ASCII whitespace character. Constrained to ASCII whitespace on
    /// purpose: classifying arbitrary multi-byte Unicode whitespace would require decoding partial
    /// scalars, which a single token's bytes may not form. Empty bytes are not whitespace-only.
    private static func isWhitespaceOnly(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else {
            return false
        }
        return bytes.allSatisfy(Self.isASCIIWhitespace)
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D:
            // space, tab, line feed, vertical tab, form feed, carriage return
            return true
        default:
            return false
        }
    }

}
