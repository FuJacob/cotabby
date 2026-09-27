import Foundation
import XCTest
@testable import Cotabby

/// Locks the generic endpoint wire contract without requiring a local server. URL policy and SSE
/// parsing are pure; URLProtocol stubs exercise the real URLSession request paths and headers.
@MainActor
final class OpenAICompatibleAPIClientTests: XCTestCase {
    func test_modelSelectionResolver_reconcilesSavedSelectionWithDiscoveredCatalog() {
        let models = [
            OpenAICompatibleModelOption(id: "alpha"),
            OpenAICompatibleModelOption(id: "beta")
        ]
        let cases: [(current: String, catalog: [OpenAICompatibleModelOption], expected: String?, label: String)] = [
            ("", models, "alpha", "empty selection adopts the first discovered model"),
            ("beta", models, "beta", "an available selection is preserved"),
            ("  beta\n", models, "beta", "surrounding whitespace does not hide an available selection"),
            ("removed-model", models, "alpha", "a stale selection is replaced by the first model"),
            ("manual-model", [], nil, "an empty catalog leaves a manual identifier untouched")
        ]

        for testCase in cases {
            XCTAssertEqual(
                OpenAICompatibleModelSelectionResolver.preferredSelection(
                    currentSelection: testCase.current,
                    discoveredModels: testCase.catalog
                ),
                testCase.expected,
                testCase.label
            )
        }
    }

    override func tearDown() {
        EndpointStubURLProtocol.handler = nil
        EndpointStubURLProtocol.holdRequests = false
        EndpointStubURLProtocol.onStart = nil
        EndpointStubURLProtocol.onStop = nil
        super.tearDown()
    }

    func test_configuration_normalizesBaseURLAndModelName() throws {
        let loopback = try configuration(baseURL: " http://127.0.0.1:11434/ ")
        XCTAssertEqual(loopback.baseURL.absoluteString, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(loopback.apiURL(path: "models").absoluteString, "http://127.0.0.1:11434/v1/models")
        XCTAssertEqual(loopback.defaultOllamaGenerateURL?.absoluteString, "http://127.0.0.1:11434/api/generate")
        XCTAssertEqual(loopback.hostScope, .loopback)
        XCTAssertNil(loopback.privacyWarning)

        // Every spelling of the default Ollama root must normalize to the exact default string,
        // because the native preload route is gated on that string match.
        for spelling in ["http://127.0.0.1:11434", "HTTP://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1///"] {
            let normalized = try configuration(baseURL: spelling)
            XCTAssertEqual(normalized.baseURL.absoluteString, "http://127.0.0.1:11434/v1", spelling)
            XCTAssertNotNil(normalized.defaultOllamaGenerateURL, spelling)
        }

        let lan = try configuration(baseURL: "http://192.168.1.50:8000/v1/")
        XCTAssertEqual(lan.baseURL.absoluteString, "http://192.168.1.50:8000/v1")
        XCTAssertNil(lan.defaultOllamaGenerateURL, "Only the default Ollama root may receive /api/generate")
        XCTAssertEqual(lan.hostScope, .localNetwork)
        XCTAssertEqual(
            lan.privacyWarning,
            "Cotabby will send typed text and any enabled context to this server on your local network."
        )

        let publicHTTPS = try configuration(baseURL: "https://models.example.com/custom/v1")
        XCTAssertEqual(publicHTTPS.baseURL.absoluteString, "https://models.example.com/custom/v1")
        XCTAssertEqual(publicHTTPS.hostScope, .publicInternet)
        XCTAssertEqual(
            publicHTTPS.privacyWarning,
            "This server is outside your Mac. Typed text and any enabled context will leave your device."
        )

        let padded = try OpenAICompatibleEndpointConfiguration(
            baseURLString: OpenAICompatibleEndpointConfiguration.defaultBaseURLString,
            modelName: "  llama3:8b \n",
            apiMode: .completions
        )
        XCTAssertEqual(padded.modelName, "llama3:8b")
    }

    /// The host scope decides both the privacy warning and whether plain HTTP is allowed, so each
    /// private-range boundary is pinned on both sides.
    func test_hostScope_classifiesLoopbackPrivateRangesAndPublicHosts() {
        let cases: [(host: String, expected: OpenAICompatibleHostScope)] = [
            ("localhost", .loopback),
            ("LOCALHOST", .loopback),
            ("ollama.localhost", .loopback),
            ("::1", .loopback),
            ("[::1]", .loopback),
            ("127.0.0.1", .loopback),
            ("127.20.30.40", .loopback),
            ("10.0.0.5", .localNetwork),
            ("172.16.0.1", .localNetwork),
            ("172.31.255.255", .localNetwork),
            ("172.15.0.1", .publicInternet),
            ("172.32.0.1", .publicInternet),
            ("192.168.1.50", .localNetwork),
            ("192.169.1.50", .publicInternet),
            ("169.254.10.20", .localNetwork),
            ("8.8.8.8", .publicInternet),
            ("256.1.1.1", .publicInternet),
            ("ollama.local", .localNetwork),
            ("fd00::1", .localNetwork),
            ("fc00::1", .localNetwork),
            ("fe80::1", .localNetwork),
            ("fec0::1", .publicInternet),
            ("2001:4860:4860::8888", .publicInternet),
            ("internal-llm", .publicInternet),
            ("models.example.com", .publicInternet)
        ]

        for testCase in cases {
            XCTAssertEqual(
                OpenAICompatibleEndpointConfiguration.hostScope(for: testCase.host),
                testCase.expected,
                testCase.host
            )
        }
    }

    func test_configuration_rejectsInsecurePublicHTTPAndInvalidComponents() {
        for insecure in [
            "http://models.example.com/v1",
            "http://internal-llm:11434/v1",
            "http://[2001:4860:4860::8888]/v1"
        ] {
            XCTAssertThrowsError(try configuration(baseURL: insecure), insecure) { error in
                XCTAssertEqual(error as? OpenAICompatibleEndpointError, .insecurePublicHTTP)
            }
        }
        for invalid in [
            "",
            "localhost:11434",
            "file:///tmp/model",
            "ftp://127.0.0.1/v1",
            "https://host/v1?token=secret",
            "http://127.0.0.1:11434/v1#fragment",
            "http://user:password@127.0.0.1:11434/v1"
        ] {
            XCTAssertThrowsError(try configuration(baseURL: invalid), invalid) { error in
                XCTAssertEqual(error as? OpenAICompatibleEndpointError, .invalidBaseURL, invalid)
            }
        }
    }

    func test_sseDecoder_mapsEachLineShapeToOneEvent() throws {
        let cases: [(line: String, mode: OpenAICompatibleAPIMode, expected: OpenAICompatibleSSEEvent)] = [
            (#"data: {"choices":[{"text":" hel"}]}"#, .completions, .text(" hel")),
            (#"{"choices":[{"text":"bare"}]}"#, .completions, .text("bare")),
            (#"data: {"choices":[{"delta":{"content":"lo"}}]}"#, .chatCompletions, .text("lo")),
            (#"data: {"choices":[{"message":{"content":"whole"}}]}"#, .chatCompletions, .text("whole")),
            (
                #"data: {"choices":[{"delta":{"content":"d"},"message":{"content":"m"}}]}"#,
                .chatCompletions,
                .text("d")
            ),
            // Field/mode mismatches and empty payloads carry no visible text.
            (#"data: {"choices":[{"delta":{"content":"chat"}}]}"#, .completions, .ignore),
            (#"data: {"choices":[{"text":"legacy"}]}"#, .chatCompletions, .ignore),
            (#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#, .chatCompletions, .ignore),
            (#"data: {"choices":[{"text":""}]}"#, .completions, .ignore),
            (#"data: {"choices":[]}"#, .completions, .ignore),
            (#"data: {}"#, .completions, .ignore),
            // SSE framing: blank lines, comments, and metadata fields are never payloads.
            ("", .completions, .ignore),
            ("   ", .completions, .ignore),
            (": keep-alive", .completions, .ignore),
            ("event: completion", .completions, .ignore),
            ("id: 42", .completions, .ignore),
            ("retry: 1000", .completions, .ignore),
            // The terminator is recognized with or without the space, prefix, or a CRLF remnant.
            ("data: [DONE]", .completions, .done),
            ("data:[DONE]", .chatCompletions, .done),
            ("[DONE]", .completions, .done),
            ("data: [DONE]\r", .completions, .done),
            // A non-empty error wins over any choices; an empty message is not an error.
            (#"data: {"error":{"message":"model missing"}}"#, .completions, .error("model missing")),
            (#"data: {"error":{"message":"boom"},"choices":[{"text":"x"}]}"#, .completions, .error("boom")),
            (#"data: {"error":{"message":""}}"#, .completions, .ignore)
        ]

        for testCase in cases {
            XCTAssertEqual(
                try OpenAICompatibleSSEDecoder.decode(testCase.line, mode: testCase.mode),
                testCase.expected,
                testCase.line
            )
        }
    }

    func test_sseDecoder_throwsMalformedResponseForNonJSONPayloads() {
        for line in ["data: {not json", "data: plain text", #"data: {"choices":"nope"}"#] {
            XCTAssertThrowsError(try OpenAICompatibleSSEDecoder.decode(line, mode: .completions), line) { error in
                XCTAssertEqual(error as? OpenAICompatibleClientError, .malformedResponse, line)
            }
        }
    }

    func test_fetchModels_usesModelsRouteAndBearerAuthorization() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/models")
            XCTAssertEqual(request.timeoutInterval, 10)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            return Self.response(
                request: request,
                body: #"{"object":"list","data":[{"id":"zeta"},{"id":"alpha","owned_by":"library"}]}"#
            )
        }

        let models = try await client.fetchModels(
            configuration: configuration(),
            apiKey: "secret"
        )

        XCTAssertEqual(models.map(\.id), ["alpha", "zeta"])
    }

    func test_completionGeneration_postsStandardPayloadAndAccumulatesSSE() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/completions")
            XCTAssertEqual(request.timeoutInterval, 120)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let json = try Self.jsonBody(request)
            XCTAssertEqual(json["model"] as? String, "gemma4:12b-mlx")
            XCTAssertEqual(json["prompt"] as? String, "Complete this")
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertEqual(json["max_tokens"] as? Int, 12)
            XCTAssertEqual(json["temperature"] as? Double, 0.2)
            XCTAssertEqual(json["top_p"] as? Double, 0.8)
            XCTAssertNil(json["messages"])
            XCTAssertNil(json["reasoning_effort"], "reasoning_effort belongs to the chat surface only")
            return Self.response(
                request: request,
                contentType: "text/event-stream",
                body: "data: {\"choices\":[{\"text\":\" hel\"}]}\n\n" +
                    "data: {\"choices\":[{\"text\":\"lo\"}]}\n\n" +
                    "data: [DONE]\n\n"
            )
        }
        var partials: [String] = []

        let output = try await client.generate(
            configuration: configuration(mode: .completions),
            apiKey: nil,
            prompt: "Complete this",
            options: .init(maxPredictionTokens: 12, temperature: 0.2, topP: 0.8),
            onPartialRawText: { partials.append($0) }
        )

        XCTAssertEqual(output, " hello")
        XCTAssertEqual(partials, [" hel", " hello"])
    }

    func test_defaultOllamaPreload_usesNativeRouteLongTimeoutAndKeepsModelResident() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/generate")
            XCTAssertEqual(request.timeoutInterval, 120)
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try Self.jsonBody(request)
            XCTAssertEqual(json["model"] as? String, "gemma4:12b-mlx")
            XCTAssertEqual(json["prompt"] as? String, "")
            XCTAssertEqual(json["stream"] as? Bool, false)
            XCTAssertEqual(json["keep_alive"] as? Int, -1)
            return Self.response(request: request, body: #"{"done":true}"#)
        }

        let didPreload = try await client.preloadDefaultOllamaModel(
            configuration: configuration(),
            apiKey: nil
        )

        XCTAssertTrue(didPreload)
    }

    func test_nonDefaultEndpoint_doesNotReceiveOllamaPreloadRequest() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { _ in
            XCTFail("A generic endpoint must not receive Ollama's native preload request")
            throw URLError(.badServerResponse)
        }

        let didPreload = try await client.preloadDefaultOllamaModel(
            configuration: configuration(baseURL: "https://models.example.com/v1"),
            apiKey: nil
        )

        XCTAssertFalse(didPreload)
    }

    func test_chatGeneration_postsSingleUserMessageAndReadsDeltaContent() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
            let json = try Self.jsonBody(request)
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages.first?["role"] as? String, "user")
            XCTAssertEqual(
                messages.first?["content"] as? String,
                "Continue the text at the end of the context. Reply with only new continuation " +
                    "text; do not repeat or quote existing text.\n\nContinue me"
            )
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertEqual(json["max_tokens"] as? Int, 8)
            XCTAssertEqual(json["reasoning_effort"] as? String, "none")
            XCTAssertNil(json["prompt"])
            return Self.response(
                request: request,
                contentType: "text/event-stream",
                body: "data: {\"choices\":[{\"delta\":{\"content\":\" next\"}}]}\n\n" +
                    "data: [DONE]\n\n"
            )
        }

        let output = try await client.generate(
            configuration: configuration(mode: .chatCompletions),
            apiKey: nil,
            prompt: "Continue me",
            options: Self.options,
            onPartialRawText: nil
        )

        XCTAssertEqual(output, " next")
    }

    func test_generationMapsNonSuccessStatus() async {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 401, body: #"{"error":{"message":"unauthorized"}}"#)
        }

        do {
            _ = try await client.generate(
                configuration: configuration(),
                apiKey: nil,
                prompt: "text",
                options: Self.options,
                onPartialRawText: nil
            )
            XCTFail("Expected the HTTP error")
        } catch let error as OpenAICompatibleClientError {
            XCTAssertEqual(error, .server(statusCode: 401))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_generationCancellationStopsTheUnderlyingRequest() async {
        let client = makeClient()
        let started = expectation(description: "endpoint request started")
        let stopped = expectation(description: "endpoint request stopped")
        EndpointStubURLProtocol.holdRequests = true
        EndpointStubURLProtocol.onStart = { started.fulfill() }
        EndpointStubURLProtocol.onStop = { stopped.fulfill() }

        let generation = Task { @MainActor in
            try await client.generate(
                configuration: configuration(),
                apiKey: nil,
                prompt: "text",
                options: Self.options,
                onPartialRawText: nil
            )
        }

        await fulfillment(of: [started], timeout: 1)
        generation.cancel()
        do {
            _ = try await generation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Foundation may surface cooperative cancellation directly.
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func test_generation_trimsAPIKeyAndOmitsAuthorizationForBlankKeys() async throws {
        let client = makeClient()
        var authorizationHeaders: [String?] = []
        EndpointStubURLProtocol.handler = { request in
            authorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization"))
            return Self.response(request: request, contentType: "text/event-stream", body: "data: [DONE]\n\n")
        }

        for apiKey in ["  secret\n", "   ", nil] as [String?] {
            _ = try await client.generate(
                configuration: configuration(),
                apiKey: apiKey,
                prompt: "text",
                options: Self.options,
                onPartialRawText: nil
            )
        }

        XCTAssertEqual(authorizationHeaders, ["Bearer secret", nil, nil])
    }

    func test_generation_blankModelNameFailsBeforeAnyRequest() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { _ in
            XCTFail("A missing model must be rejected before any request is sent")
            throw URLError(.badServerResponse)
        }
        let blankModel = try OpenAICompatibleEndpointConfiguration(
            baseURLString: OpenAICompatibleEndpointConfiguration.defaultBaseURLString,
            modelName: "   ",
            apiMode: .chatCompletions
        )

        do {
            _ = try await client.generate(
                configuration: blankModel,
                apiKey: nil,
                prompt: "text",
                options: Self.options,
                onPartialRawText: nil
            )
            XCTFail("Expected emptyModelName from generate")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleEndpointError, .emptyModelName)
        }

        do {
            _ = try await client.preloadDefaultOllamaModel(configuration: blankModel, apiKey: nil)
            XCTFail("Expected emptyModelName from preload")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleEndpointError, .emptyModelName)
        }
    }

    func test_generation_streamErrorEventThrowsAfterEarlierPartials() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            Self.response(
                request: request,
                contentType: "text/event-stream",
                body: "data: {\"choices\":[{\"text\":\" par\"}]}\n\n" +
                    "data: {\"error\":{\"message\":\"model unloaded\"}}\n\n" +
                    "data: {\"choices\":[{\"text\":\"never\"}]}\n\n"
            )
        }
        var partials: [String] = []

        do {
            _ = try await client.generate(
                configuration: configuration(mode: .completions),
                apiKey: nil,
                prompt: "text",
                options: Self.options,
                onPartialRawText: { partials.append($0) }
            )
            XCTFail("Expected the in-stream error to surface")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleClientError, .streamError("model unloaded"))
        }
        XCTAssertEqual(partials, [" par"], "Events after the error must not be delivered")
    }

    /// A server that closes the stream without `[DONE]` still produced a usable answer, but a body
    /// with no events at all is not an OpenAI-compatible stream.
    func test_generation_streamEndWithoutDoneReturnsTextButEmptyStreamIsMalformed() async throws {
        let client = makeClient()
        var body = "data: {\"choices\":[{\"text\":\" tail\"}]}\n\n"
        EndpointStubURLProtocol.handler = { request in
            Self.response(request: request, contentType: "text/event-stream", body: body)
        }

        let output = try await client.generate(
            configuration: configuration(mode: .completions),
            apiKey: nil,
            prompt: "text",
            options: Self.options,
            onPartialRawText: nil
        )
        XCTAssertEqual(output, " tail")

        body = ": keep-alive\n\n\n"
        do {
            _ = try await client.generate(
                configuration: configuration(mode: .completions),
                apiKey: nil,
                prompt: "text",
                options: Self.options,
                onPartialRawText: nil
            )
            XCTFail("Expected a stream with no events to be malformed")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleClientError, .malformedResponse)
        }
    }

    func test_fetchModels_mapsNonSuccessStatus() async throws {
        let client = makeClient()
        EndpointStubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 429, body: "{}")
        }

        do {
            _ = try await client.fetchModels(configuration: configuration(), apiKey: nil)
            XCTFail("Expected the HTTP error")
        } catch {
            XCTAssertEqual(error as? OpenAICompatibleClientError, .server(statusCode: 429))
        }
    }

    func test_connectionModel_publishesReadyFailedAndIdleStates() async throws {
        let client = makeClient()
        let connection = OpenAICompatibleConnectionModel(client: client)
        Self.retained.append(connection)
        let endpoint = try configuration()
        EndpointStubURLProtocol.handler = { request in
            Self.response(request: request, body: #"{"data":[{"id":"b"},{"id":"a"}]}"#)
        }

        await connection.refresh(configuration: endpoint, apiKey: nil)
        XCTAssertEqual(connection.models.map(\.id), ["a", "b"])
        XCTAssertEqual(connection.state, .ready(modelCount: 2))
        XCTAssertEqual(connection.state.summary, "Connected · 2 models")

        EndpointStubURLProtocol.handler = { request in
            Self.response(request: request, statusCode: 503, body: "{}")
        }
        await connection.refresh(configuration: endpoint, apiKey: nil)
        XCTAssertTrue(connection.models.isEmpty, "A failed refresh must not keep the previous catalog")
        XCTAssertEqual(connection.state, .failed("The endpoint returned HTTP 503."))

        connection.invalidate()
        XCTAssertEqual(connection.state, .idle)

        connection.setFailure("Keychain unavailable")
        XCTAssertEqual(connection.state.failureDetail, "Keychain unavailable")
    }

    private func makeClient() -> OpenAICompatibleAPIClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EndpointStubURLProtocol.self]
        let client = OpenAICompatibleAPIClient(session: URLSession(configuration: sessionConfiguration))
        Self.retained.append(client)
        return client
    }

    /// Production @MainActor classes can crash the app-hosted runner when deallocated (back-deploy
    /// executor shim); quarantine them for the process lifetime.
    private static var retained: [AnyObject] = []

    private static let options = OpenAICompatibleGenerationOptions(
        maxPredictionTokens: 8,
        temperature: 0.1,
        topP: 0.7
    )

    private func configuration(
        baseURL: String = OpenAICompatibleEndpointConfiguration.defaultBaseURLString,
        mode: OpenAICompatibleAPIMode = .chatCompletions
    ) throws -> OpenAICompatibleEndpointConfiguration {
        try OpenAICompatibleEndpointConfiguration(
            baseURLString: baseURL,
            modelName: "gemma4:12b-mlx",
            apiMode: mode
        )
    }

    private static func response(
        request: URLRequest,
        statusCode: Int = 200,
        contentType: String = "application/json",
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        return (response, Data(body.utf8))
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody ?? Self.readBodyStream(request.httpBodyStream))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4_096)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class EndpointStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var holdRequests = false
    nonisolated(unsafe) static var onStart: (() -> Void)?
    nonisolated(unsafe) static var onStop: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onStart?()
        if Self.holdRequests { return }
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

    override func stopLoading() {
        Self.onStop?()
    }
}
