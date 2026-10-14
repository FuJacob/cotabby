import XCTest
@testable import Cotabby

/// The Local Endpoint rewrite provider reuses autocomplete's endpoint and model: a chat endpoint
/// gets the instruct prompt, a completions endpoint the base prompt with stop sequences and a
/// budget sized from the selection. A stubbed URLProtocol stands in for the server.
@MainActor
final class LocalEndpointRewriteProviderTests: XCTestCase {
    private static var retained: [AnyObject] = []

    override func tearDown() {
        LocalEndpointStubURLProtocol.handler = nil
        LocalEndpointStubURLProtocol.requested = []
        super.tearDown()
    }

    private func makeProvider(
        baseURL: String = "http://127.0.0.1:11434/v1", model: String = "gemma3:4b",
        mode: OpenAICompatibleAPIMode, key: String? = nil
    ) -> LocalEndpointRewriteProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalEndpointStubURLProtocol.self]
        let client = OpenAICompatibleAPIClient(session: URLSession(configuration: configuration))
        let provider = LocalEndpointRewriteProvider(
            client: client,
            configuration: { try OpenAICompatibleEndpointConfiguration(baseURLString: baseURL, modelName: model, apiMode: mode) },
            apiKey: { key }
        )
        Self.retained.append(contentsOf: [client, provider] as [AnyObject])
        return provider
    }

    private nonisolated static func sse(_ text: String) -> (HTTPURLResponse, Data) {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let response = HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/event-stream"])!
        return (response, Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"},\"text\":\"\(escaped)\"}]}\n\ndata: [DONE]\n\n".utf8))
    }

    private nonisolated static func json(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func test_availabilityNeedsAValidConfigurationAndAModel() {
        XCTAssertTrue(makeProvider(mode: .chatCompletions).isAvailable)
        XCTAssertFalse(makeProvider(model: "", mode: .chatCompletions).isAvailable)
        XCTAssertFalse(makeProvider(baseURL: "not a url", mode: .chatCompletions).isAvailable)
        XCTAssertNotNil(makeProvider(model: "", mode: .chatCompletions).unavailableReason)
    }

    func test_sendsOffDeviceUnlessTheHostIsLoopback() {
        XCTAssertFalse(makeProvider(mode: .chatCompletions).sendsOffDevice)
        XCTAssertTrue(makeProvider(baseURL: "http://192.168.1.50:8000/v1", mode: .chatCompletions).sendsOffDevice)
        XCTAssertTrue(makeProvider(baseURL: "https://api.example.com/v1", mode: .chatCompletions).sendsOffDevice)
        XCTAssertEqual(makeProvider(baseURL: "http://192.168.1.50:8000/v1", mode: .chatCompletions).hostName, "192.168.1.50")
        XCTAssertEqual(makeProvider(baseURL: "http://192.168.1.50:8000/v1", mode: .chatCompletions).endpointURL,
                       "http://192.168.1.50:8000/v1")
    }

    func test_chatModeSendsTheInstructPromptToTheChatRoute() async throws {
        let provider = makeProvider(mode: .chatCompletions, key: "sk-test")
        LocalEndpointStubURLProtocol.handler = { request in
            let body = Self.json(request)
            XCTAssertEqual(body["model"] as? String, "gemma3:4b")
            XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] }, ["system", "user"])
            XCTAssertNil(body["prompt"])
            XCTAssertNil(body["stop"])
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            return Self.sse("Fixed text.")
        }
        let text = try await provider.rewrite(RewriteRequest(selection: "fixd text", action: .fixOnly), onPartial: { _ in })
        XCTAssertEqual(text, "Fixed text.")
        XCTAssertEqual(LocalEndpointStubURLProtocol.requested, ["http://127.0.0.1:11434/v1/chat/completions"])
    }

    func test_completionsModeSendsTheBasePromptWithStopSequencesAndABudget() async throws {
        let provider = makeProvider(mode: .completions)
        let request = RewriteRequest(selection: "fixd text", action: .fixOnly)
        LocalEndpointStubURLProtocol.handler = { httpRequest in
            let body = Self.json(httpRequest)
            XCTAssertEqual(body["prompt"] as? String, RewritePromptBuilder.basePrompt(request))
            XCTAssertNil(body["messages"])
            XCTAssertEqual(body["stop"] as? [String], RewritePromptBuilder.baseStopSequences)
            XCTAssertEqual(body["max_tokens"] as? Int, RewritePromptBuilder.tokenBudget(request))
            XCTAssertNil(body["top_k"], "no MLX-only fields for a generic endpoint")
            return Self.sse("Fixed text.")
        }
        let text = try await provider.rewrite(request, onPartial: { _ in })
        XCTAssertEqual(text, "Fixed text.")
        XCTAssertEqual(LocalEndpointStubURLProtocol.requested, ["http://127.0.0.1:11434/v1/completions"])
    }

    /// A server that ignores `stop` (or streams part of one) must not put the next example's label
    /// in the preview or the field: partials and the result are cut at the first stop sequence.
    func test_completionsModeCutsTheStopTextAServerLeftIn() async throws {
        let provider = makeProvider(mode: .completions)
        LocalEndpointStubURLProtocol.handler = { _ in Self.sse("Fixed text.\\n\\nDraft: next one") }
        var partials: [String] = []
        let text = try await provider.rewrite(RewriteRequest(selection: "fixd text", action: .fixOnly),
                                              onPartial: { partials.append($0) })
        XCTAssertEqual(text, "Fixed text.")
        XCTAssertFalse(partials.contains { $0.contains("Draft") }, "\(partials)")
    }

    func test_anUnusableConfigurationThrowsWithoutTraffic() async {
        let provider = makeProvider(model: "", mode: .chatCompletions)
        do {
            _ = try await provider.rewrite(RewriteRequest(selection: "x", action: .fixOnly), onPartial: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .noProvider)
        }
        XCTAssertTrue(LocalEndpointStubURLProtocol.requested.isEmpty)
    }
}

private final class LocalEndpointStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requested: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requested.append(request.url?.absoluteString ?? "")
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
