import Combine
import Foundation

/// Sampling values shared by the completions and chat-completions request shapes.
nonisolated struct OpenAICompatibleGenerationOptions: Equatable, Sendable {
    let maxPredictionTokens: Int
    let temperature: Double
    let topP: Double
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

    func generate(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?,
        prompt: String,
        options: OpenAICompatibleGenerationOptions,
        onPartialRawText: (@MainActor (String) -> Void)?
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

        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response)

        var accumulated = ""
        var sawEvent = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch try OpenAICompatibleSSEDecoder.decode(line, mode: configuration.apiMode) {
            case .ignore:
                continue
            case .done:
                sawEvent = true
                return accumulated
            case .text(let text):
                sawEvent = true
                accumulated += text
                onPartialRawText?(accumulated)
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
        if payload.hasPrefix(":") || payload.hasPrefix("event:")
            || payload.hasPrefix("id:") || payload.hasPrefix("retry:") {
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
        let chunk: StreamChunk
        do {
            chunk = try decoder.decode(StreamChunk.self, from: data)
        } catch {
            throw OpenAICompatibleClientError.malformedResponse
        }
        if let message = chunk.error?.message, !message.isEmpty { return .error(message) }
        guard let choice = chunk.choices?.first else { return .ignore }
        let text: String? = switch mode {
        case .completions: choice.text
        case .chatCompletions: choice.delta?.content ?? choice.message?.content
        }
        guard let text, !text.isEmpty else { return .ignore }
        return .text(text)
    }
}

private nonisolated struct ModelListResponse: Decodable {
    let data: [OpenAICompatibleModelOption]
}

private nonisolated struct CompletionRequest: Encodable {
    let model: String
    let prompt: String
    let stream = true
    let maxTokens: Int
    let temperature: Double
    let topP: Double

    init(model: String, prompt: String, options: OpenAICompatibleGenerationOptions) {
        self.model = model
        self.prompt = prompt
        maxTokens = options.maxPredictionTokens
        temperature = options.temperature
        topP = options.topP
    }

    private enum CodingKeys: String, CodingKey {
        case model, prompt, stream, temperature
        case maxTokens = "max_tokens"
        case topP = "top_p"
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

private nonisolated struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Content: Decodable { let content: String? }
        let text: String?
        let delta: Content?
        let message: Content?
    }
    struct ErrorPayload: Decodable { let message: String }

    let choices: [Choice]?
    let error: ErrorPayload?
}
