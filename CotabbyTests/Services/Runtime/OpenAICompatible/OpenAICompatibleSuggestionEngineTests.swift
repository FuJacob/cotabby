import Foundation
import XCTest
@testable import Cotabby

/// Locks the endpoint engine's adapter contract: request knobs reach the wire, endpoint and
/// transport failures are translated into Cotabby's `SuggestionClientError` vocabulary, and the
/// Ollama warmup only ever targets the default local server. A URLProtocol stub stands in for the
/// server so no network or model is involved.
@MainActor
final class OpenAICompatibleSuggestionEngineTests: XCTestCase {
    /// Production @MainActor classes can crash the app-hosted runner when deallocated (back-deploy
    /// executor shim); quarantine them for the process lifetime.
    private static var retained: [AnyObject] = []

    override func tearDown() {
        EngineStubURLProtocol.handler = nil
        EngineStubURLProtocol.requestedURLs = []
        super.tearDown()
    }

    func test_generation_sendsRequestKnobsAndReturnsRawText() async throws {
        EngineStubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key-123")
            let json = try Self.jsonBody(request)
            XCTAssertEqual(json["model"] as? String, "local-model")
            XCTAssertEqual(json["prompt"] as? String, "PROMPT")
            XCTAssertEqual(json["max_tokens"] as? Int, 8)
            XCTAssertEqual(json["temperature"] as? Double, 0.1)
            XCTAssertEqual(json["top_p"] as? Double, 0.7)
            XCTAssertNil(json["top_k"])
            return Self.sse(request, "data: {\"choices\":[{\"text\":\" world\"}]}\n\ndata: [DONE]\n\n")
        }
        let engine = makeEngine(mode: .completions, apiKey: "key-123")

        let result = try await engine.generateSuggestion(
            for: CotabbyTestFixtures.suggestionRequest(generation: 7)
        )

        XCTAssertEqual(result.rawText, " world")
        XCTAssertEqual(result.generation, 7)
    }

    func test_configurationAndModelErrors_surfaceAsUnavailable() async {
        let invalidURLEngine = makeEngine(configuration: { throw OpenAICompatibleEndpointError.invalidBaseURL })
        await assertThrows(
            invalidURLEngine,
            .unavailable(OpenAICompatibleEndpointError.invalidBaseURL.localizedDescription)
        )

        let blankModelEngine = makeEngine(modelName: "  ")
        await assertThrows(
            blankModelEngine,
            .unavailable("Choose or enter a model before generating suggestions.")
        )
    }

    func test_transportAndStreamErrors_surfaceAsGenerationFailed() async {
        EngineStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        await assertThrows(makeEngine(), .generationFailed("The endpoint returned HTTP 500."))

        EngineStubURLProtocol.handler = { request in
            Self.sse(request, "data: {\"error\":{\"message\":\"model missing\"}}\n\n")
        }
        await assertThrows(makeEngine(), .generationFailed("The endpoint reported an error: model missing"))
    }

    func test_prewarm_preloadsOnlyTheDefaultOllamaEndpoint() async {
        EngineStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"done":true}"#.utf8))
        }

        await makeEngine(baseURL: "https://models.example.com/v1")
            .prewarm(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertTrue(EngineStubURLProtocol.requestedURLs.isEmpty, "Generic endpoints must never receive /api/generate")

        await makeEngine().prewarm(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(EngineStubURLProtocol.requestedURLs, ["http://127.0.0.1:11434/api/generate"])
    }

    private func mlx404Engine(
        health: MLXServerHealth, reports: @escaping @MainActor (Int, String) -> Void
    ) -> OpenAICompatibleSuggestionEngine {
        EngineStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        return makeEngine(
            baseURL: "http://127.0.0.1:50123/v1", mode: .completions, backend: .mlx,
            onServerBroken: reports, healthCheck: { _ in health })
    }

    func test_mlxBackend_404WithHealth503ReportsBrokenAndSaysItIsRestarting() async {
        var reports: [(Int, String)] = []
        let engine = mlx404Engine(health: .generatorDead) { reports.append(($0, $1)) }
        await assertThrows(engine, .unavailable("MLX is restarting…"))
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.0, 50123)
        XCTAssertEqual(reports.first?.1, "HTTP 404")
    }

    func test_mlxBackend_404WithHealthUnreachableReportsBroken() async {
        var reports = 0
        let engine = mlx404Engine(health: .unreachable) { _, _ in reports += 1 }
        await assertThrows(engine, .unavailable("MLX is restarting…"))
        XCTAssertEqual(reports, 1)
    }

    func test_mlxBackend_404WithHealthyServerKeepsItAndFailsOnlyThisRequest() async {
        var reports = 0
        let engine = mlx404Engine(health: .healthy) { _, _ in reports += 1 }
        await assertThrows(engine, .generationFailed("The endpoint returned HTTP 404."))
        XCTAssertEqual(reports, 0)
    }

    func test_mlxBackend_cancelledDuringTheHealthProbeNeverReportsBroken() async {
        let started = HealthProbeGate()
        var reports = 0
        EngineStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let probing = makeEngine(
            baseURL: "http://127.0.0.1:50123/v1", mode: .completions, backend: .mlx,
            onServerBroken: { _, _ in reports += 1 },
            healthCheck: { _ in
                started.open()
                // Returns early when cancelled, and then claims "unreachable" like a cancelled URLSession call.
                try? await Task.sleep(for: .seconds(10))
                return .unreachable
            })
        let task = Task { try await probing.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest()) }
        await waitUntil { started.isOpen }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            guard case .cancelled? = error as? SuggestionClientError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(reports, 0)
    }

    func test_mlxBackend_streamedGenerationThreadDiedReportsBroken() async {
        EngineStubURLProtocol.handler = { request in
            Self.sse(request, "data: {\"error\":{\"message\":\"generation thread died\"}}\n\n")
        }
        var reports: [(Int, String)] = []
        let engine = makeEngine(
            baseURL: "http://127.0.0.1:50123/v1", mode: .completions, backend: .mlx,
            onServerBroken: { reports.append(($0, $1)) })
        await assertThrows(engine, .unavailable("MLX is restarting…"))
        XCTAssertEqual(reports.count, 1)
    }

    func test_endpointBackend_404DoesNotReportBroken() async {
        EngineStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        var reports = 0
        let engine = makeEngine(mode: .completions, onServerBroken: { _, _ in reports += 1 })
        await assertThrows(engine, .generationFailed("The endpoint returned HTTP 404."))
        XCTAssertEqual(reports, 0)
    }

    // MARK: - Helpers

    func test_mlxBackend_sendsMLXSamplingAndSingleLineStop() async throws {
        EngineStubURLProtocol.handler = { request in
            let json = try Self.jsonBody(request)
            XCTAssertEqual(json["top_k"] as? Int, 20)
            XCTAssertEqual(json["min_p"] as? Double, 0.08)
            XCTAssertEqual(json["repetition_penalty"] as? Double, 1.05)
            XCTAssertEqual(json["seed"] as? Int, 42)
            XCTAssertEqual(json["stop"] as? [String], ["\n"])
            return Self.sse(request, "data: {\"choices\":[{\"text\":\" world\"}]}\n\ndata: [DONE]\n\n")
        }
        let engine = makeEngine(mode: .completions, backend: .mlx)
        let result = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(result.rawText, " world")
    }

    func test_mlxBackend_multiLineSendsNoStop() async throws {
        EngineStubURLProtocol.handler = { request in
            XCTAssertNil(try Self.jsonBody(request)["stop"])
            return Self.sse(request, "data: {\"choices\":[{\"text\":\" world\"}]}\n\ndata: [DONE]\n\n")
        }
        let engine = makeEngine(mode: .completions, backend: .mlx)
        _ = try await engine.generateSuggestion(
            for: CotabbyTestFixtures.suggestionRequest(isMultiLineEnabled: true)
        )
    }

    /// The llama runtime stops decoding at a sentence end; MLX gets the same rule by closing the
    /// stream, which also makes mlx_lm.server stop on its next token write.
    func test_mlxBackend_stopsAtTheFirstSentenceEnd() async throws {
        EngineStubURLProtocol.handler = { request in
            Self.sse(request,
                "data: {\"choices\":[{\"text\":\" Thanks\"}]}\n\n" +
                "data: {\"choices\":[{\"text\":\" for the report.\"}]}\n\n" +
                "data: {\"choices\":[{\"text\":\" Next week\"}]}\n\n" +
                "data: [DONE]\n\n")
        }
        let engine = makeEngine(mode: .completions, backend: .mlx)
        let result = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(result.rawText, " Thanks for the report.")
    }

    func test_endpointBackend_doesNotStopEarly() async throws {
        EngineStubURLProtocol.handler = { request in
            Self.sse(request,
                "data: {\"choices\":[{\"text\":\" Thanks for the report.\"}]}\n\n" +
                "data: {\"choices\":[{\"text\":\" Next week\"}]}\n\n" +
                "data: [DONE]\n\n")
        }
        let result = try await makeEngine(mode: .completions)
            .generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(result.rawText, " Thanks for the report. Next week")
    }

    func test_mlxNotReady_throwsUnavailableWithoutNetwork() async {
        let engine = makeEngine(
            configuration: { throw SuggestionClientError.unavailable("MLX is starting the model…") },
            backend: .mlx
        )
        await assertThrows(engine, .unavailable("MLX is starting the model…"))
        XCTAssertTrue(EngineStubURLProtocol.requestedURLs.isEmpty)
    }

    /// Covers the MLX backend too: it reuses this engine and only changes the sampling fields and
    /// the early stop, so the same stub server answers both.
    private func makeEngine(
        baseURL: String = OpenAICompatibleEndpointConfiguration.defaultBaseURLString,
        modelName: String = "local-model",
        mode: OpenAICompatibleAPIMode = .completions,
        apiKey: String? = nil,
        backend: OpenAICompatibleSuggestionEngine.Backend = .endpoint,
        onServerBroken: (@MainActor (Int, String) -> Void)? = nil,
        healthCheck: @escaping MLXHealthCheck = { _ in .generatorDead }
    ) -> OpenAICompatibleSuggestionEngine {
        makeEngine(
            configuration: {
                try OpenAICompatibleEndpointConfiguration(
                    baseURLString: baseURL,
                    modelName: modelName,
                    apiMode: mode
                )
            },
            apiKey: apiKey,
            backend: backend,
            onServerBroken: onServerBroken,
            healthCheck: healthCheck
        )
    }

    private func makeEngine(
        configuration: @escaping @MainActor () throws -> OpenAICompatibleEndpointConfiguration,
        apiKey: String? = nil,
        backend: OpenAICompatibleSuggestionEngine.Backend = .endpoint,
        onServerBroken: (@MainActor (Int, String) -> Void)? = nil,
        healthCheck: @escaping MLXHealthCheck = { _ in .generatorDead }
    ) -> OpenAICompatibleSuggestionEngine {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EngineStubURLProtocol.self]
        let client = OpenAICompatibleAPIClient(session: URLSession(configuration: sessionConfiguration))
        let engine = OpenAICompatibleSuggestionEngine(
            client: client,
            configurationProvider: configuration,
            apiKeyProvider: { apiKey },
            backend: backend,
            onServerBroken: onServerBroken,
            healthCheck: healthCheck
        )
        Self.retained.append(contentsOf: [client, engine] as [AnyObject])
        return engine
    }

    private func assertThrows(
        _ engine: OpenAICompatibleSuggestionEngine,
        _ expected: SuggestionClientError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as SuggestionClientError {
            switch (error, expected) {
            case let (.unavailable(actual), .unavailable(wanted)),
                 let (.generationFailed(actual), .generationFailed(wanted)):
                XCTAssertEqual(actual, wanted, file: file, line: line)
            default:
                XCTFail("Expected \(expected), got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected SuggestionClientError, got \(error)", file: file, line: line)
        }
    }

    private static func sse(_ request: URLRequest, _ body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        return (response, Data(body.utf8))
    }

    /// URLSession may move a POST body into `httpBodyStream` before the protocol sees it.
    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                collected.append(buffer, count: count)
            }
            data = collected
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }
}

private final class EngineStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestedURLs: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedURLs.append(request.url?.absoluteString ?? "")
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// A flag a `@Sendable` health closure can raise and the test can poll.
final class HealthProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    func open() { lock.withLock { opened = true } }
    var isOpen: Bool { lock.withLock { opened } }
}
