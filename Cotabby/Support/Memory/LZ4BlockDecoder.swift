import Foundation

/// File overview:
/// Decodes one LZ4 *block* (the raw format, without the LZ4 frame header), the compression New
/// Outlook uses for the records of its local mail store (`HxStore.hxd`).
///
/// The format is a sequence of sequences: a token byte whose high nibble is the literal length and
/// low nibble the match length minus 4 (15 in either nibble continues in following 255-run bytes),
/// the literals, then a two-byte little-endian back-reference offset and the match copied from
/// already-decoded output. The block ends after a final literal run. Every length and offset is
/// checked against the input and the output produced so far, and the output is capped, so a
/// corrupt or crafted record throws instead of reading out of bounds or allocating without limit.
nonisolated enum LZ4BlockDecoder {
    enum DecodeError: Error, Equatable {
        case truncated
        case badOffset
        case tooLarge
    }

    /// Decodes `input[range]` as one block. `maximumOutput` bounds the result (callers pass the
    /// record's declared size).
    static func decode(_ input: UnsafeRawBufferPointer, range: Range<Int>, maximumOutput: Int) throws -> [UInt8] {
        var output: [UInt8] = []
        // A modest start: most callers try many candidate blocks that fail within a few bytes, and
        // reserving the declared size for each would allocate megabytes per failed try.
        output.reserveCapacity(min(maximumOutput, (range.count) * 4, 1 << 20))
        var index = range.lowerBound
        let end = range.upperBound

        func byte() throws -> Int {
            guard index < end else { throw DecodeError.truncated }
            defer { index += 1 }
            return Int(input[index])
        }

        func extendedLength(_ base: Int) throws -> Int {
            var length = base
            guard base == 15 else { return length }
            while true {
                let next = try byte()
                length += next
                if next != 255 { return length }
            }
        }

        while index < end {
            let token = try byte()
            let literals = try extendedLength(token >> 4)
            guard literals <= end - index else { throw DecodeError.truncated }
            guard output.count + literals <= maximumOutput else { throw DecodeError.tooLarge }
            output.append(contentsOf: UnsafeRawBufferPointer(rebasing: input[index..<(index + literals)]))
            index += literals
            if index == end { break }  // The last sequence is literals only.

            let offset = try byte() | (try byte() << 8)
            guard offset > 0, offset <= output.count else { throw DecodeError.badOffset }
            let match = try extendedLength(token & 15) + 4
            guard output.count + match <= maximumOutput else { throw DecodeError.tooLarge }
            // Byte by byte: a match may overlap the bytes it is producing (offset < length).
            var source = output.count - offset
            for _ in 0..<match {
                output.append(output[source])
                source += 1
            }
        }
        return output
    }
}
