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

    // MARK: - Helpers

    private func makeEngine(
        baseURL: String = OpenAICompatibleEndpointConfiguration.defaultBaseURLString,
        modelName: String = "local-model",
        mode: OpenAICompatibleAPIMode = .completions,
        apiKey: String? = nil
    ) -> OpenAICompatibleSuggestionEngine {
        makeEngine(
            configuration: {
                try OpenAICompatibleEndpointConfiguration(
                    baseURLString: baseURL,
                    modelName: modelName,
                    apiMode: mode
                )
            },
            apiKey: apiKey
        )
    }

    private func makeEngine(
        configuration: @escaping @MainActor () throws -> OpenAICompatibleEndpointConfiguration,
        apiKey: String? = nil
    ) -> OpenAICompatibleSuggestionEngine {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EngineStubURLProtocol.self]
        let client = OpenAICompatibleAPIClient(session: URLSession(configuration: sessionConfiguration))
        let engine = OpenAICompatibleSuggestionEngine(
            client: client,
            configurationProvider: configuration,
            apiKeyProvider: { apiKey }
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
