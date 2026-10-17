import Foundation

/// File overview:
/// Decompresses raw Snappy blocks, the compression LevelDB uses for its table blocks and Chromium's
/// IndexedDB uses for large values (`kCompressedWithSnappy`).
///
/// Why its own file: Snappy is the lowest layer of the Teams cache reader (`LevelDBReader` calls it
/// for every compressed table block, `IndexedDBReader` for compressed values) and is a complete,
/// well-specified format on its own (https://github.com/google/snappy/blob/main/format_description.txt),
/// so it is pinned by its own tests. Only decompression is needed: Cotabby never writes these files.
///
/// The format: a varint with the uncompressed length, then a stream of elements, each a tag byte
/// whose low two bits say what follows:
/// - `00` a literal: the next `n` bytes are copied to the output (`n` is in the tag, or in 1-4
///   bytes after it for long runs);
/// - `01`, `10`, `11` a copy: `length` bytes copied from `offset` bytes back in the output, with the
///   offset in 1 (plus 3 bits of the tag), 2 or 4 little-endian bytes. A copy may overlap its own
///   output (offset < length), which repeats a short pattern, so that case is copied byte by byte.
///
/// Ported from CCL Forensics' `ccl_simplesnappy` (MIT, see THIRD_PARTY_LICENSES.md). Unlike the
/// original, every length and offset is checked against the input and output before use, so a
/// corrupt or truncated block throws instead of reading out of bounds.
nonisolated enum SnappyDecoder {
    enum DecodeError: Error, Equatable {
        case truncated
        case invalidOffset
        case lengthMismatch
        case tooLarge
    }

    /// The largest output accepted. LevelDB blocks are ~4 KB and IndexedDB values a few MB; a
    /// header claiming more is corrupt, and allocating it would only waste memory.
    static let maximumOutputLength = 256 * 1024 * 1024

    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        try input.withUnsafeBufferPointer { try decompress($0) }
    }

    static func decompress(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
        try input.withUnsafeBufferPointer { try decompress($0) }
    }

    /// Works on an unsafe buffer because this runs over every block of a ~100 MB cache: bounds are
    /// checked explicitly below, once per element, instead of once per byte by `Array`.
    static func decompress(_ input: UnsafeBufferPointer<UInt8>) throws -> [UInt8] {
        var position = 0
        let expected = try readVarint(input, &position)
        guard expected <= UInt64(maximumOutputLength) else { throw DecodeError.tooLarge }
        let length = Int(expected)

        // `unsafeUninitializedCapacity` hands out raw output memory; `count` tracks how much has
        // been written, and it is what the array reports if the closure throws.
        return try [UInt8](unsafeUninitializedCapacity: length) { output, count in
            count = 0
            while position < input.count {
                let tag = input[position]
                position += 1
                if tag & 0x03 == 0 {
                    let literalLength = try readLiteralLength(tag, input, &position)
                    guard position + literalLength <= input.count else { throw DecodeError.truncated }
                    guard count + literalLength <= length else { throw DecodeError.lengthMismatch }
                    (output.baseAddress! + count).update(from: input.baseAddress! + position, count: literalLength)
                    position += literalLength
                    count += literalLength
                } else {
                    let copy = try readCopy(tag, input, &position)
                    guard copy.offset > 0, copy.offset <= count else { throw DecodeError.invalidOffset }
                    guard count + copy.length <= length else { throw DecodeError.lengthMismatch }
                    let source = count - copy.offset
                    if copy.offset >= copy.length {
                        (output.baseAddress! + count).update(from: output.baseAddress! + source, count: copy.length)
                    } else {
                        // Overlapping copy: each byte may be one this copy just wrote.
                        for index in 0..<copy.length {
                            output[count + index] = output[source + index]
                        }
                    }
                    count += copy.length
                }
            }
            guard count == length else { throw DecodeError.lengthMismatch }
        }
    }

    /// A literal's length: in the tag itself, or for 60...63 in the next 1...4 bytes (little endian).
    private static func readLiteralLength(_ tag: UInt8, _ input: UnsafeBufferPointer<UInt8>, _ position: inout Int) throws -> Int {
        var literalLength = Int(tag >> 2)
        if literalLength >= 60 {
            let extraBytes = literalLength - 59
            guard position + extraBytes <= input.count else { throw DecodeError.truncated }
            literalLength = 0
            for index in 0..<extraBytes {
                literalLength |= Int(input[position + index]) << (8 * index)
            }
            position += extraBytes
        }
        return literalLength + 1
    }

    /// A copy element's length and back-reference offset, for tag types 1 (11-bit offset), 2 (16-bit)
    /// and 3 (32-bit).
    private static func readCopy(
        _ tag: UInt8, _ input: UnsafeBufferPointer<UInt8>, _ position: inout Int
    ) throws -> (length: Int, offset: Int) {
        switch tag & 0x03 {
        case 1:
            guard position < input.count else { throw DecodeError.truncated }
            let offset = (Int(tag & 0xE0) << 3) | Int(input[position])
            position += 1
            return (Int((tag >> 2) & 0x07) + 4, offset)
        case 2:
            guard position + 2 <= input.count else { throw DecodeError.truncated }
            let offset = Int(input[position]) | Int(input[position + 1]) << 8
            position += 2
            return (Int(tag >> 2) + 1, offset)
        default:
            guard position + 4 <= input.count else { throw DecodeError.truncated }
            var offset = 0
            for index in (0..<4).reversed() { offset = offset << 8 | Int(input[position + index]) }
            position += 4
            return (Int(tag >> 2) + 1, offset)
        }
    }

    private static func readVarint(_ input: UnsafeBufferPointer<UInt8>, _ position: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while position < input.count, shift < 64 {
            let byte = input[position]
            position += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw DecodeError.truncated
    }
}
