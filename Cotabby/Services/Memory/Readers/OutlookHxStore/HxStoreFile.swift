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
nonisolated enum HxStoreFile {
    static let headerSize = 20
    static let maximumRecordSize = 64 * 1024 * 1024
    /// Characters of body text kept per message: memory keeps passages of a few hundred words, and
    /// the whole store's HTML held at once would take a gigabyte.
    static let maximumBodyCharacters = 16_000
    static let maximumHTMLCharacters = 60_000

    static func messages(at url: URL, now: Date = Date()) throws -> [HxMailRecord] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [HxMailRecord] in
            // Pass 1: find every mail record and remember where the fullest version of each message
            // is. Bodies are not converted yet: a message has several versions, and converting each
            // one would do most of the work for versions that are then replaced.
            var best: [String: Version] = [:]
            let count = buffer.count
            var offset = 8
            while offset + headerSize <= count {
                let compressed = Int(readUInt32(buffer, offset))
                let uncompressed = Int(readUInt32(buffer, offset + 4))
                let type = readUInt32(buffer, offset + 8)
                let start = offset + headerSize
                // LZ4 can expand incompressible data slightly (its worst case is n + n/255 + 16).
                let worstCaseCompressed: Int = uncompressed + uncompressed / 255 + 16
                let maximumExpansion: Int = compressed * 255
                guard compressed >= 8, compressed <= worstCaseCompressed, uncompressed <= maximumRecordSize,
                      uncompressed <= maximumExpansion, type < 64, start + compressed <= count,
                      let record = try? LZ4BlockDecoder.decode(buffer, range: start..<(start + compressed), maximumOutput: uncompressed),
                      record.count == uncompressed else {
                    offset += 1
                    continue
                }
                autoreleasepool {
                    guard var message = HxStoreRecordParser.parse(record, now: now) else { return }
                    // The fullest version wins: one with a body over one with a preview, then the later one.
                    let rank = (message.bodyHTML?.utf8.count ?? 0) * 4 + (message.sent != nil ? 2 : 0) + (message.subject != nil ? 1 : 0)
                    // Versions are matched on id *and* sender. A record without its own id reads its
                    // reply-to id instead; keyed on the id alone, a reply from anyone could replace
                    // the message it answers.
                    let key = versionKey(message)
                    guard rank >= (best[key]?.rank ?? -1) else { return }
                    message.bodyHTML = nil
                    best[key] = Version(record: message, rank: rank, block: start..<(start + compressed), size: uncompressed)
                }
                offset = start + compressed
            }

            // Pass 2: the winners' bodies, as text. Each conversion in its own autorelease pool, and
            // from the first part of the HTML only (enough for the kept text; a long thread's HTML
            // runs to megabytes).
            // A version that lost its sender is dropped when one with a sender exists for the id.
            let sendersByID = Set(best.values.compactMap { $0.record.senderAddress == nil ? nil : $0.record.messageID })
            return best.values.filter { $0.record.senderAddress != nil || !sendersByID.contains($0.record.messageID) }.map { entry in
                var message = entry.record
                guard entry.rank >= 4 else { return message }  // No body.
                autoreleasepool {
                    guard let record = try? LZ4BlockDecoder.decode(buffer, range: entry.block, maximumOutput: entry.size),
                          let html = HxStoreRecordParser.parse(record, now: now)?.bodyHTML else { return }
                    let text = TeamsMessageHTML.text(String(html.prefix(maximumHTMLCharacters)))
                    message.bodyText = String(text.prefix(maximumBodyCharacters))
                }
                return message
            }
        }
    }

    /// The fullest version of one message seen so far: its record (body not converted yet), how
    /// full it is, and where its compressed block is, so pass 2 can decode only the winners.
    private struct Version {
        let record: HxMailRecord
        let rank: Int
        let block: Range<Int>
        let size: Int
    }

    private static func versionKey(_ message: HxMailRecord) -> String {
        message.messageID + "\u{1F}" + (message.senderAddress ?? "")
    }

    private static func readUInt32(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in (0..<4).reversed() { value = value << 8 | UInt32(buffer[offset + index]) }
        return value
    }
}
