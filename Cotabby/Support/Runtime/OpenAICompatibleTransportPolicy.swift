import Foundation

/// File overview:
/// Pure rules for how much Cotabby trusts an OpenAI-compatible server's response: which redirects
/// it follows, how large and how long a streamed answer may be, and how often a growing answer is
/// handed to the main actor for normalization.
///
/// Why this lives in `Support/`: `OpenAICompatibleAPIClient` owns the sockets, but every one of these
/// decisions is deterministic. Keeping them here lets tests pin each boundary without a server, and
/// keeps the client a thin loop that applies them. The values are created per request and owned by
/// that request's `generate` call.

/// Decides whether URLSession may follow a redirect for an endpoint request.
///
/// URLSession replays a 307/308 request, body included, to the new location. The body is the user's
/// text, so a redirect may only stay on the server the request was addressed to.
nonisolated enum OpenAICompatibleRedirectPolicy {
    static func allowsRedirect(from originalURL: URL?, to redirectURL: URL?) -> Bool {
        guard let originalURL, let redirectURL,
              let original = OpenAICompatibleEndpointOrigin(url: originalURL),
              let destination = OpenAICompatibleEndpointOrigin(url: redirectURL) else {
            return false
        }
        return original == destination
    }
}

/// Upper bounds for one streamed generation. The server is not trusted to stop on its own: without
/// these, a line with no newline, an endless stream, or a slow drip can grow memory and keep the
/// request alive without limit.
nonisolated struct OpenAICompatibleStreamLimits: Equatable, Sendable {
    /// Total time for one request, from sending it to the last byte. A cold Ollama model load can
    /// take most of the 120-second idle timeout before the first byte, so this leaves room for that
    /// plus a full answer. The default session uses it as its resource timeout as well.
    static let maximumDuration: TimeInterval = 180
    /// One SSE line carries one small JSON chunk. Even a server that ignores `stream` and sends the
    /// whole completion as a single JSON line stays far below this.
    static let maximumLineBytes = 256 * 1_024
    /// Every byte read, including comments and fields Cotabby ignores (such as a reasoning channel).
    /// This also bounds the lines buffered between the reader and the main actor.
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    let maxLineBytes: Int
    let maxResponseBytes: Int
    let maxTextCharacters: Int
    let maxDuration: TimeInterval

    /// Text is capped relative to the `max_tokens` Cotabby asked for. 64 characters per token is far
    /// beyond any real tokenizer, and the 4,096 floor keeps tiny budgets from tripping on one chunk.
    static func forRequest(maxPredictionTokens: Int) -> Self {
        Self(
            maxLineBytes: maximumLineBytes,
            maxResponseBytes: maximumResponseBytes,
            maxTextCharacters: max(4_096, maxPredictionTokens * 64),
            maxDuration: maximumDuration
        )
    }
}

nonisolated enum OpenAICompatibleStreamLimitError: LocalizedError, Equatable {
    case lineTooLong
    case responseTooLarge
    case tooMuchText
    case tookTooLong

    var errorDescription: String? {
        switch self {
        case .lineTooLong: return "The endpoint sent a stream line that is too long."
        case .responseTooLarge: return "The endpoint sent more data than a suggestion needs."
        case .tooMuchText: return "The endpoint kept generating past the requested length."
        case .tookTooLong: return "The endpoint took too long to finish the suggestion."
        }
    }
}

/// Splits a response body into SSE lines while enforcing the byte limits.
///
/// Lines end at LF, CR, or CRLF, as the SSE format defines. CR and LF never occur inside a multi-byte
/// UTF-8 sequence, so splitting on raw bytes can never cut a character in half.
nonisolated struct OpenAICompatibleSSELineSplitter {
    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    private let maxLineBytes: Int
    private let maxResponseBytes: Int
    private var line: [UInt8] = []
    private var responseBytes = 0
    private var lastByteWasCarriageReturn = false

    init(maxLineBytes: Int, maxResponseBytes: Int) {
        self.maxLineBytes = maxLineBytes
        self.maxResponseBytes = maxResponseBytes
    }

    /// Returns a completed line when `byte` ends one, otherwise nil.
    mutating func append(_ byte: UInt8) throws -> String? {
        responseBytes += 1
        guard responseBytes <= maxResponseBytes else {
            throw OpenAICompatibleStreamLimitError.responseTooLarge
        }

        switch byte {
        case Self.lineFeed:
            // The LF of a CRLF pair: the CR already ended the line.
            if lastByteWasCarriageReturn {
                lastByteWasCarriageReturn = false
                return nil
            }
            return takeLine()
        case Self.carriageReturn:
            lastByteWasCarriageReturn = true
            return takeLine()
        default:
            lastByteWasCarriageReturn = false
            guard line.count < maxLineBytes else {
                throw OpenAICompatibleStreamLimitError.lineTooLong
            }
            line.append(byte)
            return nil
        }
    }

    /// The final line when the body ended without a line break.
    mutating func finish() -> String? {
        guard !line.isEmpty else { return nil }
        return takeLine()
    }

    private mutating func takeLine() -> String {
        defer { line.removeAll(keepingCapacity: true) }
        // Repair invalid UTF-8 with replacement characters, as `bytes.lines` did. Failing the whole
        // line here would turn one bad byte inside a JSON string into a dropped chunk.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: line, as: UTF8.self)
    }
}

/// Tracks what one stream has used against its limits.
nonisolated struct OpenAICompatibleStreamBudget {
    let limits: OpenAICompatibleStreamLimits
    private(set) var textCharacters = 0

    init(limits: OpenAICompatibleStreamLimits) {
        self.limits = limits
    }

    mutating func spend(_ text: String) throws {
        textCharacters += text.count
        guard textCharacters <= limits.maxTextCharacters else {
            throw OpenAICompatibleStreamLimitError.tooMuchText
        }
    }

    func checkElapsed(_ elapsed: TimeInterval) throws {
        guard elapsed <= limits.maxDuration else {
            throw OpenAICompatibleStreamLimitError.tookTooLong
        }
    }
}

/// Paces cumulative partial text so the main actor normalizes the whole answer at most once per
/// interval, however small the server makes its chunks.
///
/// Dropping an update loses nothing. Each one carries the full text so far, the next one supersedes
/// it, and the finished answer is always returned and normalized on its own. The first update is
/// never delayed, so the first ghost text appears as soon as it did before.
nonisolated struct OpenAICompatiblePartialThrottle {
    /// About one 30 Hz frame: faster updates are not visible, slower ones would make streaming lag.
    static let defaultInterval: TimeInterval = 1.0 / 30

    let minimumInterval: TimeInterval
    private var lastEmission: TimeInterval?

    init(minimumInterval: TimeInterval) {
        self.minimumInterval = minimumInterval
    }

    mutating func shouldEmit(at now: TimeInterval) -> Bool {
        if let lastEmission, now - lastEmission < minimumInterval {
            return false
        }
        lastEmission = now
        return true
    }
}
