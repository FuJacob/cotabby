import XCTest
@testable import Cotabby

/// File overview:
/// Pins the composition seam between the MLX server manager and the OpenAI-compatible engine: the
/// engine must wait for the server, then send requests to the server's exact port and model.
/// It uses the fake launcher and probe from `MLXServerManagerTests`, so no Python process runs.

/// The MLX engine is the endpoint client pointed at Cotabby's own server: nothing reaches the
/// network until the server is ready, and then requests carry its exact model id and port.
@MainActor
final class MLXEngineWiringTests: XCTestCase {
    private static var retained: [AnyObject] = []

    override func tearDown() {
        MLXWiringStubURLProtocol.handler = nil
        MLXWiringStubURLProtocol.requestedURLs = []
        super.tearDown()
    }

    func test_engineWaitsForTheServerThenUsesItsPortAndModel() async throws {
        let launcher = MLXFakeLauncher()
        let probe = MLXFakeProbe()
        let manager = MLXServerManager(
            paths: MLXPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("mlx-wire-\(UUID().uuidString)")),
            launcher: launcher, probe: probe, pickPort: { 50123 }, sleep: { _ in await Task.yield() },
            verifyListener: { _, _ in true })
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MLXWiringStubURLProtocol.self]
        let client = OpenAICompatibleAPIClient(session: URLSession(configuration: sessionConfiguration))
        let engine = OpenAICompatibleSuggestionEngine.mlx(client: client, serverManager: manager)
        Self.retained.append(contentsOf: [launcher, probe, manager, client, engine] as [AnyObject])

        await manager.apply(.running(MLXServerLaunch(
            executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"),
            modelID: "mlx-community/gemma-4-e4b-5bit", promptCacheBytes: 1 << 30)))
        do {
            _ = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
            XCTFail("expected unavailable while loading")
        } catch SuggestionClientError.unavailable(let message) {
            XCTAssertEqual(message, "MLX is loading mlx-community/gemma-4-e4b-5bit…")
        }
        XCTAssertTrue(MLXWiringStubURLProtocol.requestedURLs.isEmpty)

        await waitUntil { probe.waiting == 1 }
        probe.succeedNext()
        await waitUntil { if case .ready = manager.state { return true } else { return false } }
        MLXWiringStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data("data: {\"choices\":[{\"text\":\" world\"}]}\n\ndata: [DONE]\n\n".utf8))
        }
        let result = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
        XCTAssertEqual(result.rawText, " world")
        XCTAssertEqual(MLXWiringStubURLProtocol.requestedURLs, ["http://127.0.0.1:50123/v1/completions"])
    }
}

private final class MLXWiringStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requestedURLs: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedURLs.append(request.url?.absoluteString ?? "")
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
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
