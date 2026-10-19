import Foundation

/// File overview:
/// Reads the mail messages out of New Outlook for Mac's local store, `HxStore.hxd`.
///
/// The store (inferred from this Mac's file; Microsoft publishes no format) is a sequence of records,
/// about 90% of the file, each behind a 20-byte header:
///
/// ```
/// u32 compressed size | u32 uncompressed size | u32 record type (small) | u64 object id | LZ4 block
/// ```
///
/// Nothing in the file says where records start, so the file is scanned: at each offset the header
/// is checked for plausible sizes and the block decoded; a record is accepted only if decoding
/// exactly its compressed bytes yields exactly its declared size, which random bytes practically
/// never do, and the scan then jumps past it. Each record is handed to `HxStoreRecordParser`; the
/// store keeps several versions of a message, so the fullest version per message id is kept.
///
/// The file is memory-mapped and read only; Outlook keeps writing it, so a record cut off by a
/// concurrent write simply fails its check and is picked up by the next sync.
///
/// Given an `HxStoreScanCache`, a scan reuses what the previous scan of the file read wherever the
/// bytes are unchanged (see that type), so a sync decodes only the records Outlook wrote since.
/// Only the messages the caller asks for (`sentAfter`) are decoded in full for their bodies.
nonisolated enum HxStoreFile {
    static let headerSize = 20
    static let maximumRecordSize = 64 * 1024 * 1024
    /// Characters of body text kept per message: memory keeps passages of a few hundred words, and
    /// the whole store's HTML held at once would take a gigabyte.
    static let maximumBodyCharacters = 16_000
    static let maximumHTMLCharacters = 60_000

    /// What a scan did, for the sync log.
    struct ScanReport: Equatable, Sendable {
        var bytes = 0
        var records = 0
        /// Records and bytes taken from the previous scan without decoding.
        var reusedRecords = 0
        var reusedBytes = 0
        /// Segments kept for the next scan.
        var segments = 0
        var messages = 0
    }

    /// The store's messages, the fullest version of each, with its body as text. `sentAfter`
    /// limits the result to messages sent after it (and spares decoding the others' bodies).
    static func messages(
        at url: URL, now: Date = Date(), sentAfter: Date? = nil, cache: HxStoreScanCache? = nil
    ) throws -> [HxMailRecord] {
        try scan(at: url, now: now, sentAfter: sentAfter, cache: cache).messages
    }

    static func scan(
        at url: URL, now: Date = Date(), sentAfter: Date? = nil, cache: HxStoreScanCache? = nil
    ) throws -> (messages: [HxMailRecord], report: ScanReport) {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let previous = cache?.segments(for: url.path) ?? []
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var pass = ScanPass(buffer: buffer, previous: previous, now: now)
            pass.run()
            cache?.store(pass.segments, for: url.path)
            pass.report.segments = pass.segments.count
            let messages = pass.messages(sentAfter: sentAfter)
            pass.report.messages = messages.count
            return (messages, pass.report)
        }
    }

    /// What the bytes at `offset` are: no record (the header is implausible), a plausible header
    /// whose block does not decode to its declared size, or a record.
    enum Attempt {
        case implausible
        case failed
        case record([UInt8], compressedSize: Int)
    }

    static func attempt(_ buffer: UnsafeRawBufferPointer, at offset: Int) -> Attempt {
        let count = buffer.count
        guard offset + headerSize <= count else { return .failed }
        let compressed = Int(readUInt32(buffer, offset))
        let uncompressed = Int(readUInt32(buffer, offset + 4))
        let type = readUInt32(buffer, offset + 8)
        // LZ4 can expand incompressible data slightly (its worst case is n + n/255 + 16).
        guard compressed >= 8, compressed <= uncompressed + uncompressed / 255 + 16, uncompressed <= maximumRecordSize,
              uncompressed <= compressed * 255, type < 64 else {
            return .implausible
        }
        let start = offset + headerSize
        guard start + compressed <= count,
              let record = try? LZ4BlockDecoder.decode(buffer, range: start..<(start + compressed), maximumOutput: uncompressed),
              record.count == uncompressed else {
            return .failed
        }
        return .record(record, compressedSize: compressed)
    }

    /// The fullest version wins: one with a body over one with a preview, then the later one.
    static func rank(_ message: HxMailRecord) -> Int {
        (message.bodyHTML?.utf8.count ?? 0) * 4 + (message.sent != nil ? 2 : 0) + (message.subject != nil ? 1 : 0)
    }

    /// Versions are matched on id *and* sender. A record without its own id reads its reply-to id
    /// instead; keyed on the id alone, a reply from anyone could replace the message it answers.
    static func versionKey(messageID: String, senderAddress: String?) -> String {
        messageID + "\u{1F}" + (senderAddress ?? "")
    }

    static func readUInt32(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(buffer[offset]) | UInt32(buffer[offset + 1]) << 8 | UInt32(buffer[offset + 2]) << 16 | UInt32(buffer[offset + 3]) << 24
    }
}

/// One scan of the mapped file: pass 1 (`run`) finds every record, reusing the previous scan's
/// segments where the bytes are unchanged, and keeps the fullest version of each message; pass 2
/// (`messages`) decodes the kept versions the caller wants.
private nonisolated struct ScanPass {
    let buffer: UnsafeRawBufferPointer
    let previous: [HxStoreSegment]
    let now: Date
    private(set) var segments: [HxStoreSegment] = []
    var report = HxStoreFile.ScanReport()
    /// The fullest version found so far per message (`versionKey`).
    private var best: [String: KeptVersion] = [:]
    private var gapStart: Int?
    private var gapCandidates: [Int] = []

    init(buffer: UnsafeRawBufferPointer, previous: [HxStoreSegment], now: Date) {
        self.buffer = buffer
        self.previous = previous
        self.now = now
    }

    mutating func run() {
        let headerSize = HxStoreFile.headerSize
        report.bytes = buffer.count
        var previousIndex = 0
        var offset = 8
        while offset + headerSize <= buffer.count {
            while previousIndex < previous.count, previous[previousIndex].start < offset { previousIndex += 1 }
            if previousIndex < previous.count, previous[previousIndex].start == offset, isUnchanged(previous[previousIndex]) {
                let segment = previous[previousIndex]
                closeGap(at: offset)
                segments.append(segment)
                report.reusedBytes += segment.length
                if case let .record(size, summary) = segment.kind {
                    report.records += 1
                    report.reusedRecords += 1
                    consider(summary, block: (segment.start + headerSize)..<(segment.start + segment.length), size: size)
                }
                offset += segment.length
                continue
            }
            switch HxStoreFile.attempt(buffer, at: offset) {
            case .implausible:
                if gapStart == nil { gapStart = offset }
                offset += 1
            case .failed:
                if gapStart == nil { gapStart = offset }
                gapCandidates.append(offset)
                offset += 1
            case let .record(record, compressed):
                closeGap(at: offset)
                let end = offset + headerSize + compressed
                let summary = summarize(record)
                segments.append(HxStoreSegment(
                    start: offset, length: end - offset, digest: HxStoreDigest.digest(buffer, offset..<end),
                    kind: .record(uncompressedSize: record.count, summary: summary)
                ))
                report.records += 1
                consider(summary, block: (offset + headerSize)..<end, size: record.count)
                offset = end
            }
        }
        closeGap(at: offset)
    }

    /// Pass 2: the kept versions sent after `sentAfter` (all when nil), each decoded once more for
    /// its fields and body. A version that no longer decodes (Outlook rewrote it since pass 1) is
    /// left for the next sync, whose look-back reads it again.
    func messages(sentAfter: Date?) -> [HxMailRecord] {
        // A version that lost its sender is dropped when one with a sender exists for the id.
        let sendersByID = Set(best.values.compactMap { $0.summary.senderAddress == nil ? nil : $0.summary.messageID })
        return best.values.compactMap { entry -> HxMailRecord? in
            let summary = entry.summary
            guard summary.senderAddress != nil || !sendersByID.contains(summary.messageID) else { return nil }
            if let sentAfter {
                guard let sent = summary.sent, sent > sentAfter else { return nil }
            }
            // Each conversion in its own autorelease pool, and from the first part of the HTML only
            // (enough for the kept text; a long thread's HTML runs to megabytes).
            return autoreleasepool { () -> HxMailRecord? in
                guard let record = try? LZ4BlockDecoder.decode(buffer, range: entry.block, maximumOutput: entry.size),
                      var message = HxStoreRecordParser.parse(record, now: now) else { return nil }
                if summary.rank >= 4, let html = message.bodyHTML {
                    message.bodyText = String(
                        TeamsMessageHTML.text(String(html.prefix(HxStoreFile.maximumHTMLCharacters)))
                            .prefix(HxStoreFile.maximumBodyCharacters)
                    )
                }
                message.bodyHTML = nil
                return message
            }
        }
    }

    /// Whether `segment` from the previous scan still describes the bytes at its offset.
    private func isUnchanged(_ segment: HxStoreSegment) -> Bool {
        let end = segment.start + segment.length
        switch segment.kind {
        case let .record(_, summary):
            guard end <= buffer.count else { return false }
            if let summary, summary.sent == nil, let from = summary.sentPlausibleFrom, now >= from { return false }
            return HxStoreDigest.digest(buffer, segment.start..<end) == segment.digest
        case let .gap(candidates):
            guard HxStoreDigest.digest(buffer, gapCoverage(segment.start, end)) == segment.digest else { return false }
            // A plausible header whose block did not decode may belong to a record Outlook has
            // finished writing since; its block lies past the gap, outside the digest.
            return !candidates.contains { offset in
                if case .record = HxStoreFile.attempt(buffer, at: offset) { return true }
                return false
            }
        }
    }

    /// The bytes that decide a gap's offsets: the gap and the header bytes read past its end.
    private func gapCoverage(_ start: Int, _ end: Int) -> Range<Int> {
        start..<min(end + HxStoreFile.headerSize - 1, buffer.count)
    }

    private mutating func closeGap(at end: Int) {
        guard let start = gapStart else { return }
        segments.append(HxStoreSegment(
            start: start, length: end - start, digest: HxStoreDigest.digest(buffer, gapCoverage(start, end)),
            kind: .gap(candidates: gapCandidates)
        ))
        gapStart = nil
        gapCandidates = []
    }

    private func summarize(_ record: [UInt8]) -> HxStoreRecordSummary? {
        autoreleasepool {
            guard let message = HxStoreRecordParser.parse(record, now: now) else { return nil }
            // A time more than a day ahead is not a send time yet; it becomes one a day before it.
            let plausibleFrom = message.sent == nil
                ? HxStoreRecordParser.parse(record, now: .distantFuture)?.sent?.addingTimeInterval(-86_400)
                : nil
            return HxStoreRecordSummary(
                messageID: message.messageID, senderAddress: message.senderAddress, rank: HxStoreFile.rank(message),
                sent: message.sent, sentPlausibleFrom: plausibleFrom
            )
        }
    }

    private struct KeptVersion {
        let summary: HxStoreRecordSummary
        let block: Range<Int>
        let size: Int
    }

    private mutating func consider(_ summary: HxStoreRecordSummary?, block: Range<Int>, size: Int) {
        guard let summary else { return }
        let key = summary.versionKey
        guard summary.rank >= (best[key]?.summary.rank ?? -1) else { return }
        best[key] = KeptVersion(summary: summary, block: block, size: size)
    }
}
