import Foundation

/// File overview:
/// What one scan of New Outlook's store learned, so the next scan of the same file decodes only
/// what changed.
///
/// A full scan of `HxStore.hxd` decodes and parses every record, which took 16 to 58 seconds of a
/// whole CPU core on a real store, every 15 minutes, to find no new mail. Most of the file is the
/// same between two syncs, so `HxStoreFile` keeps, per stretch of the file, a digest of its bytes
/// and what reading it gave:
///
/// - a record: where its block is, and the few fields the scan needs to pick each message's
///   fullest version (none for a record that is not a mail message);
/// - a gap between records: the offsets in it whose header looked plausible but did not decode
///   (they are tried again, because a record Outlook was still writing fails until it is complete).
///
/// The next scan reuses a stretch only when its bytes digest the same at the same offset, so the
/// result is exactly what a full scan would give, however Outlook writes the file (in place, at
/// the end, or both). The digests are seeded per process and the cache lives in memory only: it
/// holds message ids and sender addresses, which are not written to disk outside the encrypted
/// memory store.
nonisolated final class HxStoreScanCache: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?
    private var segments: [HxStoreSegment] = []

    /// The segments of the last scan of `path`, in file order; empty for another file.
    func segments(for path: String) -> [HxStoreSegment] {
        lock.lock()
        defer { lock.unlock() }
        return self.path == path ? segments : []
    }

    func store(_ segments: [HxStoreSegment], for path: String) {
        lock.lock()
        defer { lock.unlock() }
        self.path = path
        self.segments = segments
    }
}

/// One stretch of the store as a scan read it.
nonisolated struct HxStoreSegment: Sendable {
    enum Kind: Sendable {
        /// A record: its header and LZ4 block. `summary` is nil for a record that is not a mail message.
        case record(uncompressedSize: Int, summary: HxStoreRecordSummary?)
        /// Bytes where no record starts. `candidates` are the offsets whose header was plausible.
        case gap(candidates: [Int])
    }

    let start: Int
    let length: Int
    /// `HxStoreDigest` of the stretch's bytes (for a gap, plus the header bytes read past its end).
    let digest: UInt64
    let kind: Kind
}

/// What the scan needs from a mail record to choose each message's fullest version without
/// decoding it again. The message itself is decoded only when it is returned. A class, so the
/// segments of the records that are not mail (most of the store) stay small.
nonisolated final class HxStoreRecordSummary: Sendable {
    let messageID: String
    let senderAddress: String?
    let rank: Int
    let sent: Date?
    /// For a record read without a send time: when a time in it becomes plausible (the parser
    /// accepts times up to a day ahead), after which it must be parsed again. Nil when it has none.
    let sentPlausibleFrom: Date?

    init(messageID: String, senderAddress: String?, rank: Int, sent: Date?, sentPlausibleFrom: Date?) {
        self.messageID = messageID
        self.senderAddress = senderAddress
        self.rank = rank
        self.sent = sent
        self.sentPlausibleFrom = sentPlausibleFrom
    }

    var versionKey: String { HxStoreFile.versionKey(messageID: messageID, senderAddress: senderAddress) }
}

/// A fast 64-bit digest of a byte range (about 10 GB/s on Apple silicon), for telling whether a
/// stretch of the store changed between two scans. Four independent lanes of the xxHash64 round,
/// seeded randomly per process: it is not a cryptographic hash, but the cache only compares a
/// stretch with itself at the same offset, and a random seed keeps crafted mail from aiming at a
/// collision.
nonisolated enum HxStoreDigest {
    static let seed = UInt64.random(in: .min ... .max)
    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F

    static func digest(_ buffer: UnsafeRawBufferPointer, _ range: Range<Int>, seed: UInt64 = seed) -> UInt64 {
        var lanes = (seed &+ prime1 &+ prime2, seed &+ prime2, seed, seed &- prime1)
        var index = range.lowerBound
        let end = range.upperBound
        while index + 32 <= end {
            lanes.0 = round(lanes.0, buffer.loadUnaligned(fromByteOffset: index, as: UInt64.self))
            lanes.1 = round(lanes.1, buffer.loadUnaligned(fromByteOffset: index + 8, as: UInt64.self))
            lanes.2 = round(lanes.2, buffer.loadUnaligned(fromByteOffset: index + 16, as: UInt64.self))
            lanes.3 = round(lanes.3, buffer.loadUnaligned(fromByteOffset: index + 24, as: UInt64.self))
            index += 32
        }
        var hash = mix(lanes.0) ^ mix(lanes.1 &+ 1) ^ mix(lanes.2 &+ 2) ^ mix(lanes.3 &+ 3) ^ UInt64(range.count)
        while index < end {
            hash = mix(hash ^ UInt64(buffer[index]))
            index += 1
        }
        return mix(hash)
    }

    private static func round(_ lane: UInt64, _ input: UInt64) -> UInt64 {
        let sum = lane &+ input &* prime2
        return ((sum << 31) | (sum >> 33)) &* prime1
    }

    /// SplitMix64's finalizer: every input bit reaches every output bit.
    private static func mix(_ value: UInt64) -> UInt64 {
        var mixed = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
