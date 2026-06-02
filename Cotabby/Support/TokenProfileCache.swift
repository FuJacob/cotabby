import Foundation

/// File overview:
/// A compact on-disk encoding of a constrained-decode `TokenProfile`, so the expensive full-vocabulary
/// detokenize scan that builds it runs once per model and is reloaded from disk on later launches
/// instead of rebuilt every time the constrained decoder first runs.
///
/// Why this file exists:
/// Building a `TokenProfile` calls the engine's detokenizer once per vocabulary token (often 100k+),
/// which delays the first constrained completion after launch. The profile is a pure function of the
/// model's vocabulary, so it can be cached. Only the per-token raw bytes and the end-of-generation bit
/// need storing; every other flag (`isControl`, whitespace-only, newline) is derived from the bytes by
/// `TokenProfile.build`, so decoding reconstructs an identical profile. A fingerprint in the header
/// ties a cache file to one model + vocabulary, and a mismatch (or any malformed/truncated data)
/// decodes to nil so the caller rebuilds. The cache is therefore strictly an optimization: a wrong or
/// corrupt file can never produce a wrong profile, only a rebuild.
enum TokenProfileCache {
    private static let magic: [UInt8] = Array("CTKP".utf8)   // CoTabby Token Profile
    private static let version: UInt8 = 1
    /// Defensive cap so a corrupt vocab-size field cannot drive a giant allocation; real vocabularies
    /// are well under this.
    private static let maxVocabSize = 5_000_000

    /// Serializes `profile` with a `fingerprint` (model + vocabulary identity) in the header.
    static func encode(_ profile: TokenProfile, fingerprint: UInt64) -> Data {
        var data = Data()
        data.append(contentsOf: magic)
        data.append(version)
        appendUInt64(fingerprint, to: &data)
        appendUInt32(UInt32(clamping: profile.entries.count), to: &data)
        for entry in profile.entries {
            appendUInt32(UInt32(clamping: entry.bytes.count), to: &data)
            data.append(contentsOf: entry.bytes)
            data.append(entry.isEndOfGeneration ? 1 : 0)
        }
        return data
    }

    /// Reconstructs a `TokenProfile` from `data`, or nil when the magic / version / fingerprint do not
    /// match or the data is malformed. Reconstruction goes through `TokenProfile.build`, so the derived
    /// flags are recomputed from the stored bytes and exactly match a freshly-built profile.
    static func decode(_ data: Data, expectedFingerprint: UInt64) -> TokenProfile? {
        var reader = Reader(data)
        guard reader.readBytes(magic.count) == magic,
              reader.readUInt8() == version,
              reader.readUInt64() == expectedFingerprint,
              let vocabSize = reader.readUInt32().map(Int.init),
              vocabSize <= maxVocabSize else {
            return nil
        }
        var tokenBytes: [[UInt8]] = []
        var endOfGeneration: [Bool] = []
        tokenBytes.reserveCapacity(vocabSize)
        endOfGeneration.reserveCapacity(vocabSize)
        for _ in 0 ..< vocabSize {
            guard let byteCount = reader.readUInt32().map(Int.init),
                  let bytes = reader.readBytes(byteCount),
                  let flag = reader.readUInt8() else {
                return nil
            }
            tokenBytes.append(bytes)
            endOfGeneration.append(flag & 1 == 1)
        }
        guard reader.isAtEnd else {
            return nil
        }
        return TokenProfile.build(
            vocabSize: vocabSize,
            bytesFor: { tokenBytes[$0] },
            isControl: { tokenBytes[$0].isEmpty },
            isEndOfGeneration: { endOfGeneration[$0] }
        )
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    /// Forward-only byte reader that returns nil rather than trapping when asked for more than remains,
    /// so a truncated cache file decodes to nil instead of crashing.
    private struct Reader {
        private let bytes: [UInt8]
        private var offset = 0

        init(_ data: Data) {
            bytes = [UInt8](data)
        }

        var isAtEnd: Bool { offset == bytes.count }

        mutating func readBytes(_ count: Int) -> [UInt8]? {
            guard count >= 0, offset + count <= bytes.count else {
                return nil
            }
            defer { offset += count }
            return Array(bytes[offset ..< offset + count])
        }

        mutating func readUInt8() -> UInt8? {
            readBytes(1)?.first
        }

        mutating func readUInt32() -> UInt32? {
            guard let slice = readBytes(4) else { return nil }
            return UInt32(slice[0]) | UInt32(slice[1]) << 8 | UInt32(slice[2]) << 16 | UInt32(slice[3]) << 24
        }

        mutating func readUInt64() -> UInt64? {
            guard let slice = readBytes(8) else { return nil }
            var value: UInt64 = 0
            for index in 0 ..< 8 {
                value |= UInt64(slice[index]) << (8 * index)
            }
            return value
        }
    }
}
