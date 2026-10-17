import CotabbyInference
import Foundation

/// File overview:
/// The native boundary around the in-process embedding model (`CotabbyEmbeddingEngine`, llama.cpp).
///
/// Why it exists as its own type: the C++ engine owns a model and a context that must never be used
/// from two threads at once, and two kinds of callers want it. Background indexing embeds passages in
/// batches for minutes; a suggestion's memory lookup needs one query vector *now*. The core
/// serializes them with one lock and gives queries priority: an arriving query cancels the passage
/// batch in progress (the native engine stops at its next decode, within tens of milliseconds) and
/// takes the model; the batch is retried once no query is waiting.
///
/// Like `LlamaRuntimeCore`, this is deliberately not a Swift actor: native calls block for their
/// whole duration, and an actor would hold its executor (and every other caller) meanwhile. Callers
/// run it off the main actor. Owned by `MemoryEngine` for as long as memory is on.
nonisolated final class EmbeddingCore: @unchecked Sendable {
    enum EmbeddingError: LocalizedError {
        case notLoaded
        case loadFailed(String)
        case failed
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "The embedding model is not loaded."
            case .loadFailed(let path): return "Could not load the embedding model at \(path)."
            case .failed: return "Embedding failed."
            case .cancelled: return "Embedding was cancelled."
            }
        }
    }

    /// Per-text token limit (passages are chunked to fit), tokens decoded together, and texts packed
    /// per decode. The batch fixes memory: measured 882 MB in total for Qwen3-Embedding-0.6B Q8_0.
    static let maxTextTokens: Int32 = 512
    static let batchTokens: Int32 = 1024
    static let maxSequences: Int32 = 16

    /// Qwen3-Embedding is trained with an instruction on the query side only; passages are embedded
    /// as they are. One instruction per retrieval task.
    enum QueryTask {
        case conversationContext
        case answerQuestion

        var instruction: String {
            switch self {
            case .conversationContext:
                return "Given text someone is writing in a conversation, retrieve earlier messages that are relevant to it"
            case .answerQuestion:
                return "Given a question someone was asked, retrieve messages that contain the answer"
            }
        }
    }

    private var engine = CotabbyEmbeddingEngine()
    private let lock = NSLock()
    private let counterLock = NSLock()
    private var waitingQueries = 0
    private var passageBatchRunning = false
    private(set) var dimensions = 0
    private(set) var modelPath: String?

    deinit {
        engine.unloadModel()
    }

    func load(modelPath path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard modelPath != path else { return }
        guard engine.loadModel(path, -1, Self.maxTextTokens, Self.batchTokens, Self.maxSequences) == .ok else {
            modelPath = nil
            dimensions = 0
            throw EmbeddingError.loadFailed(path)
        }
        modelPath = path
        dimensions = Int(engine.getDimensions())
    }

    func unload() {
        engine.cancel()
        lock.lock()
        defer { lock.unlock() }
        engine.unloadModel()
        modelPath = nil
        dimensions = 0
    }

    /// One query vector, ahead of any background batch.
    func embedQuery(_ text: String, task: QueryTask) throws -> [Float] {
        counterLock.lock()
        waitingQueries += 1
        let interrupt = passageBatchRunning
        counterLock.unlock()
        if interrupt { engine.cancel() }
        defer {
            counterLock.lock()
            waitingQueries -= 1
            counterLock.unlock()
        }
        let instructed = "Instruct: \(task.instruction)\nQuery: \(text)"
        return try embedLocked([instructed])[0]
    }

    /// Vectors for passages (no instruction), for background indexing. Yields to waiting queries
    /// before taking the model.
    func embedPassages(_ texts: [String]) throws -> [[Float]] {
        while true {
            while hasWaitingQueries { usleep(5_000) }
            setPassageBatchRunning(true)
            defer { setPassageBatchRunning(false) }
            do {
                return try embedLocked(texts)
            } catch EmbeddingError.cancelled where hasWaitingQueries || !Task.isCancelled {
                continue  // A query took the model; embed this batch again after it.
            }
        }
    }

    private func setPassageBatchRunning(_ running: Bool) {
        counterLock.lock()
        passageBatchRunning = running
        counterLock.unlock()
    }

    private var hasWaitingQueries: Bool {
        counterLock.lock()
        defer { counterLock.unlock() }
        return waitingQueries > 0
    }

    private func embedLocked(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        let dimensions = dimensions
        guard modelPath != nil, dimensions > 0 else { throw EmbeddingError.notLoaded }

        // The engine takes the texts back to back in one UTF-8 buffer with byte offsets, which
        // crosses the C++ boundary as two plain arrays instead of an array of strings.
        var bytes: [CChar] = []
        var offsets: [Int32] = [0]
        for text in texts {
            bytes.append(contentsOf: text.utf8.map { CChar(bitPattern: $0) })
            offsets.append(Int32(bytes.count))
        }
        bytes.append(0)
        var output = [Float](repeating: 0, count: texts.count * dimensions)
        let status = bytes.withUnsafeBufferPointer { text in
            offsets.withUnsafeBufferPointer { offsetBuffer in
                output.withUnsafeMutableBufferPointer { out in
                    engine.embedBatch(text.baseAddress, offsetBuffer.baseAddress, Int32(texts.count), out.baseAddress, Int32(out.count))
                }
            }
        }
        switch status {
        case .ok:
            return (0..<texts.count).map { Array(output[($0 * dimensions)..<(($0 + 1) * dimensions)]) }
        case .cancelled:
            throw EmbeddingError.cancelled
        case .not_loaded:
            throw EmbeddingError.notLoaded
        default:
            throw EmbeddingError.failed
        }
    }
}
