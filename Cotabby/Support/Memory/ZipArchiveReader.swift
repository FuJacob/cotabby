import Compression
import Foundation

/// File overview:
/// Reads named entries out of a ZIP archive held in memory. Word, PowerPoint and Excel files
/// (`.docx`, `.pptx`, `.xlsx`) are ZIP archives of XML parts, so this is how memory gets at their text.
///
/// Why our own reader: Foundation has no ZIP API, and spawning `unzip` per document would be slow
/// and would hand untrusted archives to another program. The format needed here is small: the end
/// record, the central directory, each entry's local header, and entries stored plainly or with
/// DEFLATE (decoded by Apple's Compression framework, whose `COMPRESSION_ZLIB` is raw DEFLATE).
///
/// Documents come from shared drives, so an archive is untrusted input. Every offset and length is
/// checked against the data, entries and their expanded size are capped (a "zip bomb" throws instead
/// of filling memory), and ZIP64 and encrypted archives are refused. Pure and `Sendable`.
nonisolated struct ZipArchiveReader: Sendable {
    enum ZipError: Error, Equatable {
        case notAZip
        case unsupported
        case corrupt
        case tooLarge
    }

    struct Entry: Equatable, Sendable {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    static let maximumEntries = 20_000
    /// The most one entry may expand to. A presentation's slide XML is kilobytes; a spreadsheet's
    /// shared strings can be megabytes.
    static let maximumEntryBytes = 32 * 1024 * 1024
    /// DEFLATE compresses text at most about 1000:1; anything claiming more is a bomb.
    static let maximumRatio = 1_000

    let data: Data
    let entries: [Entry]

    init(data: Data) throws {
        self.data = data
        entries = try Self.centralDirectory(data)
    }

    /// The names of the entries, in archive order.
    var names: [String] { entries.map(\.name) }

    /// The expanded bytes of the entry called `name`, nil when there is none.
    func contents(of name: String) throws -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return try contents(of: entry)
    }

    func contents(of entry: Entry) throws -> Data {
        guard entry.uncompressedSize <= Self.maximumEntryBytes,
              entry.uncompressedSize <= max(entry.compressedSize, 1) * Self.maximumRatio else { throw ZipError.tooLarge }
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count, Self.u32(data, header) == 0x0403_4B50 else { throw ZipError.corrupt }
        let start = header + 30 + Int(Self.u16(data, header + 26)) + Int(Self.u16(data, header + 28))
        guard start >= 0, entry.compressedSize >= 0, start + entry.compressedSize <= data.count else { throw ZipError.corrupt }
        let compressed = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0:
            guard compressed.count == entry.uncompressedSize else { throw ZipError.corrupt }
            return compressed
        case 8:
            return try Self.inflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ZipError.unsupported
        }
    }

    // MARK: - Format

    /// Where the end-of-central-directory record starts. It is in the last 64 KB plus its 22 bytes
    /// (the comment can be up to 65,535 bytes), searched backwards for its signature.
    private static func endOfCentralDirectory(_ data: Data) throws -> Int {
        guard data.count >= 22 else { throw ZipError.notAZip }
        var position = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while position >= floor {
            if u32(data, position) == 0x0605_4B50 { return position }
            position -= 1
        }
        throw ZipError.notAZip
    }

    private static func centralDirectory(_ data: Data) throws -> [Entry] {
        let end = try endOfCentralDirectory(data)
        let count = Int(u16(data, end + 10))
        let size = Int(u32(data, end + 12))
        let offset = Int(u32(data, end + 16))
        // 0xFFFF / 0xFFFFFFFF here mean the real values are in a ZIP64 record: not supported.
        guard count != 0xFFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF else { throw ZipError.unsupported }
        guard count <= maximumEntries else { throw ZipError.tooLarge }
        guard offset + size <= end else { throw ZipError.corrupt }

        var entries: [Entry] = []
        var cursor = offset
        for _ in 0..<count {
            guard cursor + 46 <= end, u32(data, cursor) == 0x0201_4B50 else { throw ZipError.corrupt }
            let flags = u16(data, cursor + 8)
            guard flags & 0x1 == 0 else { throw ZipError.unsupported }  // Encrypted.
            let nameLength = Int(u16(data, cursor + 28))
            let extraLength = Int(u16(data, cursor + 30))
            let commentLength = Int(u16(data, cursor + 32))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= end else { throw ZipError.corrupt }
            let nameBytes = data.subdata(in: (data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLength))
            entries.append(Entry(
                name: String(lossyUTF8: nameBytes),
                method: u16(data, cursor + 10),
                compressedSize: Int(u32(data, cursor + 20)),
                uncompressedSize: Int(u32(data, cursor + 24)),
                localHeaderOffset: Int(u32(data, cursor + 42))
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            compressed.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = destination.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, expectedSize, from, compressed.count, nil, COMPRESSION_ZLIB)
            }
        }
        // The decoder stops at the buffer's end, so a short result is the only failure to catch.
        guard written == expectedSize else { throw ZipError.corrupt }
        return output
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        let high = UInt16(data[base + 1]) << 8
        return high | UInt16(data[base])
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        var value: UInt32 = 0
        for index in (0..<4).reversed() { value = value << 8 | UInt32(data[base + index]) }
        return value
    }
}
