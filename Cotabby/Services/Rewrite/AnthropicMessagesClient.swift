import Foundation

/// File overview:
/// Calls Claude through Anthropic's own Messages API (`POST /v1/messages`) over raw HTTP, because
/// Swift has no official Anthropic SDK and Anthropic's guidance for such languages is the native API
/// rather than an OpenAI-compatible shim. Streams the reply as Server-Sent Events and keeps only the
/// text deltas: current Claude models think by default and send `thinking` blocks first (empty unless
/// requested), which are not part of the rewrite.
///
/// Request shape, per Anthropic's reference:
/// - headers `x-api-key` and `anthropic-version: 2023-06-01`;
/// - `max_tokens` is required (16,000 leaves room without ever truncating a rewrite);
/// - no sampling parameters, which current models reject;
/// - `output_config.effort: low` on the 5-series models (all of which list effort support; no beta
///   header needed), since a rewrite is a simple task and lower effort answers faster;
/// - server-side refusal fallback (`fallbacks: "default"` with the `server-side-fallback-2026-07-01`
///   beta header, which is the only header date that accepts `"default"`) on the models whose
///   classifier refusals it covers, so a safety decline is retried on Anthropic's recommended
///   fallback model in the same stream instead of failing. Claude Haiku 5.5 has no server-side
///   fallback, so it is never sent there.
/// A `refusal` stop reason that survives is reported as an error, and an empty key fails before
/// any request. Owned by `APIRewriteProvider`; Settings uses `listModels`.
@MainActor
final class AnthropicMessagesClient {
    static let apiVersion = "2023-06-01"
    static let maxTokens = 16_000
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated deinit {}

    /// Streams one rewrite and returns the full text. `onPartial` receives the cumulative text.
    func streamMessage(
        _ message: AnthropicMessage,
        baseURL: String,
        apiKey: String?,
        timeout: TimeInterval,
        onPartial: (@MainActor (String) -> Void)?
    ) async throws -> String {
        try Self.requireKey(apiKey)
        let request = try Self.messagesRequest(message, baseURL: baseURL, apiKey: apiKey, timeout: timeout)
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw AnthropicMessagesError.api(status: http.statusCode, message: Self.errorMessage(in: data))
        }
        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch try Self.streamEvent(fromLine: line) {
            case .text(let text)?:
                accumulated += text
                onPartial?(accumulated)
            case .stop?:
                return accumulated
            case nil:
                continue
            }
        }
        // The stream ended without `message_stop`: a proxy or server closed it part-way. What arrived
        // may read like a whole message, so it is an error, never a preview Replace could paste.
        throw AnthropicMessagesError.incomplete
    }

    /// What one SSE line means for the rewrite. Thinking deltas, pings and block boundaries are nil.
    enum StreamEvent: Equatable {
        case text(String)
        case stop
    }

    /// Reads one SSE line: a text delta, the end of the message, or nothing that matters. A refusal
    /// that survived the fallback and an in-stream error are thrown, since neither carries a rewrite.
    static func streamEvent(fromLine line: String) throws -> StreamEvent? {
        guard line.hasPrefix("data:"),
              let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return nil }
        let delta = event["delta"] as? [String: Any]
        switch type {
        case "content_block_delta":
            guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String else { return nil }
            return .text(text)
        case "message_delta":
            if delta?["stop_reason"] as? String == "refusal" { throw AnthropicMessagesError.refused }
            return nil
        case "error":
            let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Unknown error"
            throw AnthropicMessagesError.api(status: 200, message: message)
        case "message_stop":
            return .stop
        default:
            return nil
        }
    }

    /// The `POST /v1/messages` request: required headers and `max_tokens`, no sampling parameters,
    /// low effort and the refusal fallback only on the models documented to take them.
    private static func messagesRequest(
        _ message: AnthropicMessage, baseURL: String, apiKey: String?, timeout: TimeInterval
    ) throws -> URLRequest {
        var request = try Self.request(baseURL: baseURL, path: "messages", apiKey: apiKey, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        var body: [String: Any] = [
            "model": message.model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": message.system,
            "messages": [["role": "user", "content": message.user]]
        ]
        if supportsEffort(message.model) {
            body["output_config"] = ["effort": "low"]
        }
        if supportsDefaultFallback(message.model) {
            request.setValue(fallbackBeta, forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The model IDs the key can use (`GET /v1/models`), newest first as the API returns them.
    func listModels(baseURL: String, apiKey: String?) async throws -> [String] {
        try Self.requireKey(apiKey)
        let request = try Self.request(baseURL: baseURL, path: "models?limit=100", apiKey: apiKey, timeout: 10)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AnthropicMessagesError.api(status: http.statusCode, message: Self.errorMessage(in: data))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    /// Every 5-series model supports `output_config.effort`; some older ones do not (Haiku 4.5
    /// rejects it), so only the 5-series gets it.
    static func supportsEffort(_ model: String) -> Bool {
        ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5"].contains { model.hasPrefix($0) }
    }

    /// The models with classifier refusals that server-side fallback covers: Fable 5.1, Fable 5,
    /// Opus 5.5, Opus 5 and Sonnet 5.5. Haiku 5.5 has classifier refusals but no server-side fallback.
    static func supportsDefaultFallback(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-fable-5", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    /// Every Messages API call needs a key; without one the request could only come back 401.
    private static func requireKey(_ apiKey: String?) throws {
        guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnthropicMessagesError.missingKey
        }
    }

    private static func request(baseURL: String, path: String, apiKey: String?, timeout: TimeInterval) throws -> URLRequest {
        let root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + "/" + path), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else {
            throw AnthropicMessagesError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    /// The API's `{"type":"error","error":{"message":…}}` text, else a short fallback.
    private static func errorMessage(in data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["error"] as? [String: Any])?["message"] as? String ?? "The Claude API returned an error."
    }
}

/// One Messages API call: the model, the rewrite rules as the system prompt, and the draft as the
/// single user turn. A value of its own so the client's call stays small and tests can build one.
nonisolated struct AnthropicMessage: Equatable, Sendable {
    let model: String
    let system: String
    let user: String
}

nonisolated enum AnthropicMessagesError: LocalizedError, Equatable {
    case invalidURL
    case missingKey
    case incomplete
    case refused
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The Claude API address is not valid."
        case .missingKey: return "Add your Claude API key in Settings → Rewrite."
        case .incomplete: return "Claude's reply ended early — try again."
        case .refused: return "Claude declined to rewrite this text."
        case .api(let status, let message): return "Claude API error \(status): \(message)"
        }
    }
}
