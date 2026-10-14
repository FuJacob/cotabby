import Combine
import Foundation

/// Sampling values shared by the completions and chat-completions request shapes.
nonisolated struct OpenAICompatibleGenerationOptions: Equatable, Sendable {
    let maxPredictionTokens: Int
    let temperature: Double
    let topP: Double
    /// MLX-only sampling fields. Nil for every other server, so they never receive unknown keys.
    let mlx: MLXCompletionOptions?
    /// The standard OpenAI `stop` field for completions requests: generation ends before any of
    /// these strings. Nil sends nothing. When `mlx.stop` is non-empty it wins (autocomplete's MLX
    /// path sets it per request); otherwise this list is sent. Selection rewrite uses it for its
    /// base-model prompt on an endpoint or MLX server.
    let stop: [String]?

    init(
        maxPredictionTokens: Int,
        temperature: Double,
        topP: Double,
        mlx: MLXCompletionOptions? = nil,
        stop: [String]? = nil
    ) {
        self.maxPredictionTokens = maxPredictionTokens
        self.temperature = temperature
        self.topP = topP
        self.mlx = mlx
        self.stop = stop
    }
}

/// One chat message for requests that bring their own system prompt (selection rewrite), unlike
/// autocomplete's single-message continuation prompt.
nonisolated struct OpenAICompatibleChatMessage: Encodable, Equatable, Sendable {
    let role: String
    let content: String
}

enum OpenAICompatibleClientError: LocalizedError, Equatable {
    case invalidResponse
    case server(statusCode: Int)
    case malformedResponse
    case streamError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The endpoint returned an invalid HTTP response."
        case .server(let code): return "The endpoint returned HTTP \(code)."
        case .malformedResponse: return "The endpoint returned an invalid OpenAI-compatible response."
        case .streamError(let message): return "The endpoint reported an error: \(message)"
        }
    }
}

/// Stateless HTTP boundary for OpenAI-compatible local servers.
///
/// `URLSession` owns socket work off the main actor. This object stays main-actor isolated so the
/// cumulative partial callback can feed Cotabby's UI-facing generation pipeline directly.
@MainActor
final class OpenAICompatibleAPIClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchModels(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?
    ) async throws -> [OpenAICompatibleModelOption] {
        var request = URLRequest(url: configuration.apiURL(path: "models"), timeoutInterval: 10)
        applyHeaders(to: &request, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        let payload = try decoder.decode(ModelListResponse.self, from: data)
        return payload.data.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Loads the selected model through Ollama's native API without tying that cold start to a
    /// cancellable autocomplete request. Returning `false` means the configured endpoint is not
    /// Cotabby's known local Ollama default, so callers can treat warmup as an intentional no-op.
    func preloadDefaultOllamaModel(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?
    ) async throws -> Bool {
        guard !configuration.modelName.isEmpty else {
            throw OpenAICompatibleEndpointError.emptyModelName
        }
        guard let url = configuration.defaultOllamaGenerateURL else { return false }

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request, apiKey: apiKey)
        request.httpBody = try encoder.encode(OllamaPreloadRequest(model: configuration.modelName))

        let (_, response) = try await session.data(for: request)
        try Self.validate(response)
        return true
    }

    func generate(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?,
        prompt: String,
        options: OpenAICompatibleGenerationOptions,
        onPartialRawText: (@MainActor (String) -> Void)?,
        stopWhen: (@MainActor (String, Int) -> Bool)? = nil
    ) async throws -> String {
        guard !configuration.modelName.isEmpty else {
            throw OpenAICompatibleEndpointError.emptyModelName
        }

        var request = URLRequest(
            url: configuration.apiURL(path: configuration.apiMode.route),
            timeoutInterval: 120
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyHeaders(to: &request, apiKey: apiKey)
        request.httpBody = try requestBody(
            mode: configuration.apiMode,
            model: configuration.modelName,
            prompt: prompt,
            options: options
        )

        return try await streamSSE(
            request,
            mode: configuration.apiMode,
            onPartialRawText: onPartialRawText,
            stopWhen: stopWhen
        )
    }

    /// Streams a chat completion for a caller-built message list (selection rewrite). Sends only
    /// model, messages and stream, so hosted models that reject sampling or reasoning fields accept it.
    func streamChat(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?,
        messages: [OpenAICompatibleChatMessage],
        timeout: TimeInterval,
        onPartialRawText: (@MainActor (String) -> Void)?
    ) async throws -> String {
        guard !configuration.modelName.isEmpty else { throw OpenAICompatibleEndpointError.emptyModelName }
        var request = URLRequest(
            url: configuration.apiURL(path: OpenAICompatibleAPIMode.chatCompletions.route),
            timeoutInterval: timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyHeaders(to: &request, apiKey: apiKey)
        request.httpBody = try encoder.encode(
            ChatMessagesRequest(model: configuration.modelName, messages: messages)
        )
        return try await streamSSE(request, mode: .chatCompletions, onPartialRawText: onPartialRawText, stopWhen: nil)
    }

    /// The SSE loop shared by `generate` and `streamChat`. It returns the accumulated text at the
    /// `[DONE]` sentinel, reports each cumulative partial, and treats a stream with no data events
    /// as a malformed response rather than an empty suggestion. `stopWhen` ends the stream early
    /// with the text so far.
    private func streamSSE(
        _ request: URLRequest,
        mode: OpenAICompatibleAPIMode,
        onPartialRawText: (@MainActor (String) -> Void)?,
        stopWhen: (@MainActor (String, Int) -> Bool)?
    ) async throws -> String {
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response)

        var accumulated = ""
        var sawEvent = false
        var textEvents = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch try OpenAICompatibleSSEDecoder.decode(line, mode: mode) {
            case .ignore:
                continue
            case .done:
                return accumulated
            case .text(let text):
                sawEvent = true
                textEvents += 1
                accumulated += text
                onPartialRawText?(accumulated)
                // Returning leaves the `for await`, which cancels the URLSession task and closes the
                // socket. mlx_lm.server's handler fails on its next write and marks the request
                // stopped, and its generation thread drops it at the next token, so an early stop
                // here saves server time as well as the wait.
                if let stopWhen, stopWhen(accumulated, textEvents) {
                    return accumulated
                }
            case .error(let message):
                throw OpenAICompatibleClientError.streamError(message)
            }
        }

        guard sawEvent else { throw OpenAICompatibleClientError.malformedResponse }
        return accumulated
    }

    private func applyHeaders(to request: inout URLRequest, apiKey: String?) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func requestBody(
        mode: OpenAICompatibleAPIMode,
        model: String,
        prompt: String,
        options: OpenAICompatibleGenerationOptions
    ) throws -> Data {
        switch mode {
        case .completions:
            return try encoder.encode(CompletionRequest(model: model, prompt: prompt, options: options))
        case .chatCompletions:
            return try encoder.encode(ChatCompletionRequest(model: model, prompt: prompt, options: options))
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleClientError.server(statusCode: http.statusCode)
        }
    }
}

/// Observable model catalog shared by Settings and the Home status card.
/// A refresh generation prevents a slow response for an old URL from replacing a newer catalog.
@MainActor
final class OpenAICompatibleConnectionModel: ObservableObject {
    @Published private(set) var models: [OpenAICompatibleModelOption] = []
    @Published private(set) var state: OpenAICompatibleConnectionState = .idle

    private let client: OpenAICompatibleAPIClient
    private var refreshGeneration: UInt64 = 0

    init(client: OpenAICompatibleAPIClient) {
        self.client = client
    }

    func invalidate() {
        refreshGeneration &+= 1
        models = []
        state = .idle
    }

    func setFailure(_ message: String) {
        refreshGeneration &+= 1
        models = []
        state = .failed(message)
    }

    func refresh(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?
    ) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .connecting
        do {
            let fetched = try await client.fetchModels(configuration: configuration, apiKey: apiKey)
            guard refreshGeneration == generation else { return }
            models = fetched
            state = .ready(modelCount: fetched.count)
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == generation else { return }
            models = []
            state = .failed(error.localizedDescription)
        }
    }
}

nonisolated enum OpenAICompatibleSSEEvent: Equatable {
    case ignore
    case done
    case text(String)
    case error(String)
}

/// Pure line decoder for OpenAI's data-only SSE streams.
nonisolated enum OpenAICompatibleSSEDecoder {
    static func decode(
        _ line: String,
        mode: OpenAICompatibleAPIMode,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> OpenAICompatibleSSEEvent {
        var payload = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return .ignore }
        if isMetadataLine(payload) {
            return .ignore
        }
        if payload.hasPrefix("data:") {
            payload.removeFirst("data:".count)
            payload = payload.trimmingCharacters(in: .whitespaces)
        }
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8) else {
            throw OpenAICompatibleClientError.malformedResponse
        }
        return event(from: try streamChunk(from: data, decoder: decoder), mode: mode)
    }

    private static func streamChunk(from data: Data, decoder: JSONDecoder) throws -> StreamChunk {
        do {
            return try decoder.decode(StreamChunk.self, from: data)
        } catch {
            throw OpenAICompatibleClientError.malformedResponse
        }
    }

    private static func event(
        from chunk: StreamChunk,
        mode: OpenAICompatibleAPIMode
    ) -> OpenAICompatibleSSEEvent {
        if let message = chunk.error?.message, !message.isEmpty { return .error(message) }
        guard let choice = chunk.choices?.first else { return .ignore }
        let text: String? = switch mode {
        case .completions: choice.text
        case .chatCompletions: choice.delta?.content ?? choice.message?.content
        }
        guard let text, !text.isEmpty else { return .ignore }
        return .text(text)
    }

    private static func isMetadataLine(_ payload: String) -> Bool {
        [":", "event:", "id:", "retry:"].contains { payload.hasPrefix($0) }
    }
}

private nonisolated struct ModelListResponse: Decodable {
    let data: [OpenAICompatibleModelOption]
}

/// Ollama treats an empty, non-streaming generate request as a model load. `keep_alive = -1`
/// keeps the weights resident until Ollama is stopped or explicitly asked to unload them.
private nonisolated struct OllamaPreloadRequest: Encodable {
    let model: String
    let prompt = ""
    let stream = false
    let keepAlive = -1

    private enum CodingKeys: String, CodingKey {
        case model, prompt, stream
        case keepAlive = "keep_alive"
    }
}

private nonisolated struct CompletionRequest: Encodable {
    let model: String
    let prompt: String
    let stream = true
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    // MLX-only fields. Optionals are left out of the JSON when nil (synthesized `encodeIfPresent`).
    let topK: Int?
    let minP: Double?
    let repetitionPenalty: Double?
    let seed: Int?
    let stop: [String]?

    init(model: String, prompt: String, options: OpenAICompatibleGenerationOptions) {
        self.model = model
        self.prompt = prompt
        maxTokens = options.maxPredictionTokens
        temperature = options.temperature
        topP = options.topP
        topK = options.mlx?.topK
        minP = options.mlx?.minP
        repetitionPenalty = options.mlx?.repetitionPenalty
        seed = options.mlx?.seed
        // MLX's own non-empty stop list wins; else the general list; an empty list is never sent.
        let mlxStop = options.mlx.flatMap { $0.stop.isEmpty ? nil : $0.stop }
        stop = mlxStop ?? options.stop.flatMap { $0.isEmpty ? nil : $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case model, prompt, stream, temperature, seed, stop
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case minP = "min_p"
        case repetitionPenalty = "repetition_penalty"
    }
}

private nonisolated struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let stream = true
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    /// Autocomplete needs visible continuation tokens immediately. Reasoning-capable local models
    /// can otherwise spend Cotabby's entire short token budget on an invisible thinking channel.
    /// `reasoning_effort` is part of the OpenAI-compatible chat surface and is ignored by models
    /// that do not expose reasoning.
    let reasoningEffort = "none"

    init(model: String, prompt: String, options: OpenAICompatibleGenerationOptions) {
        self.model = model
        // The shared prompt is shaped as a base-model continuation and intentionally ends at the
        // caret. Chat models otherwise tend to answer by repeating that final line, which Cotabby
        // correctly normalizes away and makes the user wait for a suggestion that never appears.
        // A short instruction in the same user message preserves the single-message wire contract
        // while making the expected output explicit for instruction-tuned endpoint models.
        messages = [Message(
            role: "user",
            content: "Continue the text at the end of the context. Reply with only new continuation " +
                "text; do not repeat or quote existing text.\n\n" + prompt
        )]
        maxTokens = options.maxPredictionTokens
        temperature = options.temperature
        topP = options.topP
    }

    private enum CodingKeys: String, CodingKey {
        case model, messages, stream, temperature
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case reasoningEffort = "reasoning_effort"
    }
}

/// A rewrite request: model, messages and stream only. Sampling and reasoning fields are left out
/// because hosted models differ in which of them they reject (some refuse `max_tokens` or a
/// non-default temperature), and a rewrite needs none of them.
private nonisolated struct ChatMessagesRequest: Encodable {
    let model: String
    let messages: [OpenAICompatibleChatMessage]
    let stream = true
}

private nonisolated struct StreamChunk: Decodable {
    struct Choice: Decodable {
        let text: String?
        let delta: StreamContent?
        let message: StreamContent?
    }
    struct ErrorPayload: Decodable { let message: String }

    let choices: [Choice]?
    let error: ErrorPayload?
}

private nonisolated struct StreamContent: Decodable {
    let content: String?
}
