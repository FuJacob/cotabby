import Accelerate
import Foundation

/// File overview:
/// The in-memory vector index conversation memory searches: every passage's embedding, held as
/// half-precision rows (`HalfPrecision`), scored exactly against a query with Accelerate.
///
/// Why an exact scan rather than an approximate graph (HNSW/USearch): memory searches are filtered
/// (one conversation, the same people, the enabled sources, never an excluded chat), and a scan
/// applies the filter first, so it can never come back short the way a post-filtered graph search
/// does. It is also fast enough: tens of thousands of 1024-wide rows score in a few milliseconds.
/// `VectorSearching` is the seam where an approximate index can come in if the corpus outgrows a
/// scan (around half a million passages).
///
/// Memory: half-precision rows (2 KB per passage for 1024 dimensions), converted to Float32 a block at a
/// time while scoring. Nothing is written to disk here; the sealed vectors live in `MemoryStore`.
nonisolated protocol VectorSearching: AnyObject, Sendable {
    var count: Int { get }
    func replaceAll(_ vectors: [MemoryStore.StoredVector])
    func upsert(_ vectors: [MemoryStore.StoredVector])
    func remove(recordIDs: Set<String>)
    func search(_ query: [Float], limit: Int, where include: (FlatVectorIndex.Entry) -> Bool)
        -> [(entry: FlatVectorIndex.Entry, score: Float)]
}

nonisolated final class FlatVectorIndex: VectorSearching, @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let passageID: String
        let recordID: String
        let source: String
        let conversationKey: String
        let timestamp: Double
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var rows: [UInt16] = []
    private var rowByPassage: [String: Int] = [:]
    private(set) var dimensions: Int

    /// Rows converted and scored per step: bounds the Float32 scratch buffer to ~4 MB.
    static let blockRows = 1024

    init(dimensions: Int) {
        self.dimensions = dimensions
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    /// Approximate resident size of the vectors, for the pane.
    var byteSize: Int {
        lock.lock()
        defer { lock.unlock() }
        return rows.count * MemoryLayout<UInt16>.size
    }

    func replaceAll(_ vectors: [MemoryStore.StoredVector]) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)
        rowByPassage.removeAll(keepingCapacity: true)
        appendLocked(vectors)
    }

    func upsert(_ vectors: [MemoryStore.StoredVector]) {
        lock.lock()
        defer { lock.unlock() }
        // An empty index takes its width from the first vector it is given.
        if dimensions == 0, let first = vectors.first { dimensions = first.vector.count }
        var fresh: [MemoryStore.StoredVector] = []
        for vector in vectors where vector.vector.count == dimensions {
            if let row = rowByPassage[vector.passageID] {
                entries[row] = Self.entry(vector)
                rows.replaceSubrange((row * dimensions)..<((row + 1) * dimensions), with: vector.vector)
            } else {
                fresh.append(vector)
            }
        }
        appendLocked(fresh)
    }

    private func appendLocked(_ vectors: [MemoryStore.StoredVector]) {
        if dimensions == 0, let first = vectors.first { dimensions = first.vector.count }
        for vector in vectors where vector.vector.count == dimensions && rowByPassage[vector.passageID] == nil {
            rowByPassage[vector.passageID] = entries.count
            entries.append(Self.entry(vector))
            rows.append(contentsOf: vector.vector)
        }
    }

    /// Removes every passage of the given messages (swap-with-last, so removal is O(1) per row).
    func remove(recordIDs: Set<String>) {
        guard !recordIDs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var row = 0
        while row < entries.count {
            guard recordIDs.contains(entries[row].recordID) else {
                row += 1
                continue
            }
            let last = entries.count - 1
            rowByPassage[entries[row].passageID] = nil
            if row != last {
                entries[row] = entries[last]
                rowByPassage[entries[row].passageID] = row
                // Copied in place through one buffer: passing a slice of `rows` to its own
                // `replaceSubrange` would copy the whole index on every removal.
                let dimensions = dimensions
                rows.withUnsafeMutableBufferPointer { buffer in
                    for offset in 0..<dimensions {
                        buffer[row * dimensions + offset] = buffer[last * dimensions + offset]
                    }
                }
            }
            entries.removeLast()
            rows.removeLast(dimensions)
        }
    }

    /// The `limit` most similar passages among those `include` accepts, best first. Vectors are
    /// L2-normalized, so the dot product is the cosine similarity.
    func search(_ query: [Float], limit: Int, where include: (Entry) -> Bool) -> [(entry: Entry, score: Float)] {
        lock.lock()
        defer { lock.unlock() }
        let dimensions = dimensions
        guard limit > 0, query.count == dimensions, dimensions > 0, !entries.isEmpty else { return [] }

        let candidates = entries.indices.filter { include(entries[$0]) }
        guard !candidates.isEmpty else { return [] }
        var scores = [Float](repeating: 0, count: candidates.count)
        var block = [Float](repeating: 0, count: Self.blockRows * dimensions)

        rows.withUnsafeBufferPointer { rowBuffer in
            block.withUnsafeMutableBufferPointer { blockBuffer in
                query.withUnsafeBufferPointer { queryBuffer in
                    var start = 0
                    while start < candidates.count {
                        let end = min(start + Self.blockRows, candidates.count)
                        // Gather and widen this block's rows to Float32.
                        for (offset, row) in candidates[start..<end].enumerated() {
                            var source = vImage_Buffer(
                                data: UnsafeMutableRawPointer(mutating: rowBuffer.baseAddress! + row * dimensions),
                                height: 1, width: vImagePixelCount(dimensions), rowBytes: dimensions * 2
                            )
                            var target = vImage_Buffer(
                                data: blockBuffer.baseAddress! + offset * dimensions,
                                height: 1, width: vImagePixelCount(dimensions), rowBytes: dimensions * 4
                            )
                            vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
                        }
                        // scores[start..<end] = block · query
                        // (rows × dimensions) · (dimensions × 1) = (rows × 1)
                        scores.withUnsafeMutableBufferPointer { scoreBuffer in
                            vDSP_mmul(
                                blockBuffer.baseAddress!, 1, queryBuffer.baseAddress!, 1,
                                scoreBuffer.baseAddress! + start, 1,
                                vDSP_Length(end - start), 1, vDSP_Length(dimensions)
                            )
                        }
                        start = end
                    }
                }
            }
        }
        return scores.indices
            .sorted { scores[$0] > scores[$1] }
            .prefix(limit)
            .map { (entry: entries[candidates[$0]], score: scores[$0]) }
    }

    private static func entry(_ vector: MemoryStore.StoredVector) -> Entry {
        Entry(passageID: vector.passageID, recordID: vector.recordID, source: vector.source,
              conversationKey: vector.conversationKey, timestamp: vector.timestamp)
    }
}
