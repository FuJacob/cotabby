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
    /// A redirect to another server was refused, so URLSession delivered the 3xx response itself.
    case redirectRefused(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The endpoint returned an invalid HTTP response."
        case .server(let code): return "The endpoint returned HTTP \(code)."
        case .malformedResponse: return "The endpoint returned an invalid OpenAI-compatible response."
        case .streamError(let message): return "The endpoint reported an error: \(message)"
        case .redirectRefused(let code):
            return "The endpoint redirected to a different server (HTTP \(code)). Cotabby does not follow " +
                "redirects to other servers; enter the final address as the Server URL."
        }
    }
}

/// Stateless HTTP boundary for OpenAI-compatible local servers.
///
/// `URLSession` owns socket work off the main actor. This object stays main-actor isolated so the
/// cumulative partial callback can feed Cotabby's UI-facing generation pipeline directly. Byte-level
/// stream parsing runs off the main actor; only whole lines cross back.
@MainActor
final class OpenAICompatibleAPIClient {
    private let session: URLSession
    private let partialUpdateInterval: TimeInterval
    /// Passed as the task delegate of every request, so the same-server redirect rule holds even
    /// for a session that was not built by `makeDefaultSession()`.
    private let redirectGuard = OpenAICompatibleRedirectGuard()
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// `partialUpdateInterval` paces `onPartialRawText` (see `OpenAICompatiblePartialThrottle`);
    /// tests pass zero to observe every chunk.
    init(
        session: URLSession = OpenAICompatibleAPIClient.makeDefaultSession(),
        partialUpdateInterval: TimeInterval = OpenAICompatiblePartialThrottle.defaultInterval
    ) {
        self.session = session
        self.partialUpdateInterval = partialUpdateInterval
    }

    /// A session of the endpoint's own instead of `URLSession.shared`, which keeps cookies, a disk
    /// cache, and stored credentials that any other part of the process may also use. Nothing about
    /// one endpoint request should persist into, or be read back by, another.
    nonisolated static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The per-request `timeoutInterval` is an idle timeout; this bounds a request's total time,
        // so a server that drips one byte at a time cannot keep it open indefinitely.
        configuration.timeoutIntervalForResource = OpenAICompatibleStreamLimits.maximumDuration
        return configuration
    }

    nonisolated static func makeDefaultSession() -> URLSession {
        URLSession(
            configuration: makeSessionConfiguration(),
            delegate: OpenAICompatibleRedirectGuard(),
            delegateQueue: nil
        )
    }

    func fetchModels(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?
    ) async throws -> [OpenAICompatibleModelOption] {
        var request = URLRequest(url: configuration.apiURL(path: "models"), timeoutInterval: 10)
        applyHeaders(to: &request, apiKey: apiKey)
        let (data, response) = try await session.data(for: request, delegate: redirectGuard)
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

        let (_, response) = try await session.data(for: request, delegate: redirectGuard)
        try Self.validate(response)
        return true
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

        let limits = OpenAICompatibleStreamLimits.forRequest(maxPredictionTokens: options.maxPredictionTokens)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
        try Self.validate(response)

        var budget = OpenAICompatibleStreamBudget(limits: limits)
        var throttle = OpenAICompatiblePartialThrottle(minimumInterval: partialUpdateInterval)
        var accumulated = ""
        var sawEvent = false
        for try await line in Self.lines(of: bytes, limits: limits) {
            try Task.checkCancellation()
            try budget.checkElapsed(ProcessInfo.processInfo.systemUptime - startedAt)
            switch try OpenAICompatibleSSEDecoder.decode(line, mode: configuration.apiMode) {
            case .ignore:
                continue
            case .done:
                sawEvent = true
                return accumulated
            case .text(let text):
                sawEvent = true
                try budget.spend(text)
                accumulated += text
                // Every callback makes the engine normalize the whole answer on the main actor, so
                // pace them; the returned text below is always complete.
                if throttle.shouldEmit(at: ProcessInfo.processInfo.systemUptime) {
                    onPartialRawText?(accumulated)
                }
            case .error(let message):
                throw OpenAICompatibleClientError.streamError(message)
            }
        }

        // The line stream finishes quietly, not with an error, when this task is cancelled.
        try Task.checkCancellation()
        guard sawEvent else { throw OpenAICompatibleClientError.malformedResponse }
        return accumulated
    }

    /// Reads the body byte by byte on a detached task and yields whole SSE lines. Iterating bytes on
    /// the main actor would hop executors per byte; this keeps the per-line cost `bytes.lines` had
    /// while adding the line and response caps it lacked. Ending or abandoning the stream (a
    /// returned answer, a thrown limit, a cancelled request) cancels the reader, which cancels the
    /// URLSession task.
    nonisolated private static func lines(
        of bytes: URLSession.AsyncBytes,
        limits: OpenAICompatibleStreamLimits
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task.detached {
                var splitter = OpenAICompatibleSSELineSplitter(
                    maxLineBytes: limits.maxLineBytes,
                    maxResponseBytes: limits.maxResponseBytes
                )
                do {
                    for try await byte in bytes {
                        if let line = try splitter.append(byte) {
                            continuation.yield(line)
                        }
                    }
                    if let line = splitter.finish() {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
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
        // Same-server redirects are followed before this point, so a 3xx here is one the redirect
        // guard refused.
        if (300..<400).contains(http.statusCode) {
            throw OpenAICompatibleClientError.redirectRefused(statusCode: http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleClientError.server(statusCode: http.statusCode)
        }
    }
}

/// Refuses any redirect that would carry an endpoint request to a different server.
///
/// It is both the default session's delegate and the task delegate of every request the client
/// sends, so the rule applies to the streaming call regardless of which session runs it. URLSession
/// calls it on its delegate queue; it holds no state, so it is safe from any thread.
nonisolated final class OpenAICompatibleRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Compare with the original request, not the current one, so a chain of hops can never
        // drift away from the configured server one step at a time.
        let allowed = OpenAICompatibleRedirectPolicy.allowsRedirect(
            from: task.originalRequest?.url,
            to: request.url
        )
        // nil tells URLSession to deliver the 3xx response instead of following it.
        completionHandler(allowed ? request : nil)
    }
}

/// Observable model catalog shared by Settings and the Home status card.
/// A refresh generation prevents a slow response for an old URL from replacing a newer catalog.
@MainActor
final class OpenAICompatibleConnectionModel: ObservableObject {
    /// The catalog lives inside the phase that produced it, so a published model list can never
    /// disagree with the connection state's model count or outlive a failure.
    private enum Phase {
        case idle
        /// A refresh keeps listing the previous catalog until its answer arrives, so the model
        /// picker does not empty out while the endpoint is re-queried.
        case connecting(retained: [OpenAICompatibleModelOption])
        case ready([OpenAICompatibleModelOption])
        case failed(String)
    }

    @Published private var phase: Phase = .idle

    var models: [OpenAICompatibleModelOption] {
        switch phase {
        case .connecting(let models), .ready(let models):
            return models
        case .idle, .failed:
            return []
        }
    }

    var state: OpenAICompatibleConnectionState {
        switch phase {
        case .idle:
            return .idle
        case .connecting:
            return .connecting
        case .ready(let models):
            return .ready(modelCount: models.count)
        case .failed(let message):
            return .failed(message)
        }
    }

    private let client: OpenAICompatibleAPIClient
    private var refreshGeneration: UInt64 = 0

    init(client: OpenAICompatibleAPIClient) {
        self.client = client
    }

    func invalidate() {
        refreshGeneration &+= 1
        phase = .idle
    }

    func setFailure(_ message: String) {
        refreshGeneration &+= 1
        phase = .failed(message)
    }

    func refresh(
        configuration: OpenAICompatibleEndpointConfiguration,
        apiKey: String?
    ) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        phase = .connecting(retained: models)
        do {
            let fetched = try await client.fetchModels(configuration: configuration, apiKey: apiKey)
            guard refreshGeneration == generation else { return }
            phase = .ready(fetched)
        } catch is CancellationError {
            return
        } catch {
            guard refreshGeneration == generation else { return }
            phase = .failed(error.localizedDescription)
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
