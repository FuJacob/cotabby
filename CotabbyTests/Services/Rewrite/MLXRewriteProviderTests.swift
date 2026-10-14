import XCTest
@testable import Cotabby

/// The MLX rewrite provider waits for the on-demand server, then streams the instruct prompt to
/// the server's exact port and model. A stubbed URLProtocol stands in for the HTTP server and the
/// manager's launcher/probe are the fakes from `MLXServerManagerTests`, so nothing real runs.
@MainActor
final class MLXRewriteProviderTests: XCTestCase {
    private static var retained: [AnyObject] = []
    private let model = "mlx-community/gemma-4-e4b-it-4bit"

    override func tearDown() {
        MLXRewriteStubURLProtocol.handler = nil
        MLXRewriteStubURLProtocol.requested = []
        super.tearDown()
    }

    private let baseModel = "mlx-community/gemma-4-e4b-5bit"

    private struct Rig {
        let provider: MLXRewriteProvider
        let controller: MLXRewriteServerController
        let launcher: MLXFakeLauncher
        let probe: MLXFakeProbe
        /// Autocomplete's own server, which the provider may reuse.
        let shared: MLXServerManager
        let sharedLauncher: MLXFakeLauncher
        let sharedProbe: MLXFakeProbe
    }

    /// `autocomplete` is the engine autocomplete is on; `modelID` is autocomplete's MLX model, the
    /// one a rewrite uses (there is no rewrite-only model).
    private func makeRig(
        toolchain: MLXToolchainState? = nil, cached: Bool = true,
        health: MLXServerHealth = .generatorDead,
        healthCheck: MLXHealthCheck? = nil,
        autocomplete: SuggestionEngineKind = .llamaOpenSource,
        modelID: String? = nil
    ) -> Rig {
        let model = modelID ?? self.model
        let launcher = MLXFakeLauncher()
        let probe = MLXFakeProbe()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mlx-rp-\(UUID().uuidString)")
        let manager = MLXServerManager(
            paths: MLXPaths(root: root), launcher: launcher, probe: probe, pickPort: { 50300 },
            sleep: { _ in await Task.yield() }, baseEnvironment: [:], verifyListener: { _, _ in true },
            pidFileURL: MLXPaths(root: root).rewriteServerPIDFile)
        let sharedLauncher = MLXFakeLauncher()
        let sharedProbe = MLXFakeProbe()
        let shared = MLXServerManager(
            paths: MLXPaths(root: root), launcher: sharedLauncher, probe: sharedProbe, pickPort: { 50400 },
            sleep: { _ in await Task.yield() }, baseEnvironment: [:], verifyListener: { _, _ in true })
        let ready = MLXToolchainState.ready(MLXToolchain(
            serverExecutable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"),
            pythonExecutable: URL(fileURLWithPath: "/mlx/bin/python"), version: "0.32.0", isCotabbyInstall: true))
        let models = cached ? [MLXCachedModel(repoID: MLXRepoID(model)!, snapshotURL: root, sizeBytes: 1, modelType: "gemma4", isInstruct: true)] : []
        let controller = MLXRewriteServerController(
            manager: manager, toolchain: { toolchain ?? ready }, cachedModels: { models }, rejectedModels: { [:] },
            isAppleSilicon: true,
            // The 5-minute idle wait really sleeps (and is cancelled with the test); polls yield.
            sleep: { duration in
                if duration >= .seconds(60) { try await Task.sleep(for: duration) } else { await Task.yield() }
            })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MLXRewriteStubURLProtocol.self]
        let client = OpenAICompatibleAPIClient(session: URLSession(configuration: configuration))
        let provider = MLXRewriteProvider(
            controller: controller, autocompleteServer: shared, autocompleteEngine: { autocomplete },
            modelID: { model }, client: client, healthCheck: healthCheck ?? { _ in health },
            sleep: { _ in await Task.yield() })
        Self.retained.append(contentsOf: [launcher, probe, manager, controller, client, provider, shared, sharedLauncher, sharedProbe] as [AnyObject])
        return Rig(provider: provider, controller: controller, launcher: launcher, probe: probe,
                   shared: shared, sharedLauncher: sharedLauncher, sharedProbe: sharedProbe)
    }

    /// Brings autocomplete's server to `.ready` on port 50400 with `modelID`.
    private func readyAutocompleteServer(_ rig: Rig, modelID: String) async {
        let launch = MLXServerLaunch(
            executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"), modelID: modelID, promptCacheBytes: 1 << 30)
        Task { await rig.shared.apply(.running(launch)) }
        await waitUntil { rig.sharedProbe.waiting >= 1 }
        rig.sharedProbe.succeedNext()
        await waitUntil { if case .ready = rig.shared.state { return true } else { return false } }
    }

    private static let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Fixed text.\"},\"text\":\"Fixed text.\"}]}\n\ndata: [DONE]\n\n"

    private func okHandler(_ check: ((URLRequest) -> Void)? = nil) {
        MLXRewriteStubURLProtocol.handler = { request in
            check?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data(Self.sse.utf8))
        }
    }

    // MARK: - Which server and which prompt shape

    func test_baseModelOnTheOnDemandServerUsesTheCompletionsRouteAndBasePrompt() async throws {
        let rig = makeRig(modelID: baseModel)
        let request = RewriteRequest(selection: "fixd text", action: .fixOnly)
        okHandler { httpRequest in
            let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(httpRequest)) as? [String: Any]) ?? [:]
            XCTAssertEqual(body["prompt"] as? String, RewritePromptBuilder.basePrompt(request))
            XCTAssertEqual(body["stop"] as? [String], RewritePromptBuilder.baseStopSequences)
            XCTAssertEqual(body["max_tokens"] as? Int, RewritePromptBuilder.tokenBudget(request))
            XCTAssertNil(body["messages"])
        }
        async let result = rig.provider.rewrite(request, onPartial: { _ in })
        await waitUntil { rig.probe.waiting >= 1 }
        rig.probe.succeedNext()
        let text = try await result
        XCTAssertEqual(text, "Fixed text.")
        XCTAssertEqual(MLXRewriteStubURLProtocol.requested, ["http://127.0.0.1:50300/v1/completions"])
    }

    /// The base path cuts at the first stop sequence like the llama path, so "Draft:" never reaches
    /// the preview even if the server streams it.
    func test_baseModelOutputIsCutAtTheStopText() async throws {
        let rig = makeRig(modelID: baseModel)
        MLXRewriteStubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            let body = "data: {\"choices\":[{\"text\":\"Fixed text.\\n\\nDraft: next\"}]}\n\ndata: [DONE]\n\n"
            return (response, Data(body.utf8))
        }
        var partials: [String] = []
        async let result = rig.provider.rewrite(
            RewriteRequest(selection: "fixd text", action: .fixOnly), onPartial: { partials.append($0) })
        await waitUntil { rig.probe.waiting >= 1 }
        rig.probe.succeedNext()
        let text = try await result
        XCTAssertEqual(text, "Fixed text.")
        XCTAssertFalse(partials.contains { $0.contains("Draft") }, "\(partials)")
    }

    func test_aReadyAutocompleteServerIsReusedWithoutStartingASecondOne() async throws {
        let rig = makeRig(autocomplete: .mlx)
        await readyAutocompleteServer(rig, modelID: model)
        okHandler()
        var partials: [String] = []
        let text = try await rig.provider.rewrite(
            RewriteRequest(selection: "fixd text", action: .fixOnly), onPartial: { partials.append($0) })
        XCTAssertEqual(text, "Fixed text.")
        XCTAssertEqual(MLXRewriteStubURLProtocol.requested, ["http://127.0.0.1:50400/v1/chat/completions"])
        XCTAssertTrue(rig.launcher.launches.isEmpty, "no second server")
        XCTAssertNotEqual(partials.first, MLXRewriteProvider.loadingNote, "the shared server is already loaded")
    }

    func test_aReadyBaseAutocompleteServerGetsTheBasePromptOnItsPort() async throws {
        let rig = makeRig(autocomplete: .mlx, modelID: baseModel)
        await readyAutocompleteServer(rig, modelID: baseModel)
        okHandler()
        _ = try await rig.provider.rewrite(
            RewriteRequest(selection: "fixd text", action: .fixOnly), onPartial: { _ in })
        XCTAssertEqual(MLXRewriteStubURLProtocol.requested, ["http://127.0.0.1:50400/v1/completions"])
        XCTAssertTrue(rig.launcher.launches.isEmpty)
    }

    func test_autocompleteOnMLXWhileItsServerLoadsWaitsForItAndNeverStartsASecondServer() async throws {
        let rig = makeRig(autocomplete: .mlx)
        let launch = MLXServerLaunch(
            executable: URL(fileURLWithPath: "/mlx/bin/mlx_lm.server"), modelID: model, promptCacheBytes: 1 << 30)
        Task { await rig.shared.apply(.running(launch)) }
        await waitUntil { rig.sharedProbe.waiting >= 1 }
        XCTAssertTrue(rig.provider.isAvailable, "a loading server is worth waiting for")
        okHandler()
        var partials: [String] = []
        async let result = rig.provider.rewrite(
            RewriteRequest(selection: "fixd", action: .fixOnly), onPartial: { partials.append($0) })
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(MLXRewriteStubURLProtocol.requested.isEmpty, "nothing is sent before the server is ready")
        rig.sharedProbe.succeedNext()
        let text = try await result
        XCTAssertEqual(text, "Fixed text.")
        XCTAssertEqual(partials.first, MLXRewriteProvider.loadingNote)
        XCTAssertEqual(MLXRewriteStubURLProtocol.requested, ["http://127.0.0.1:50400/v1/chat/completions"])
        XCTAssertTrue(rig.launcher.launches.isEmpty, "no second server")
        XCTAssertEqual(rig.sharedLauncher.launches.count, 1)
    }

    func test_autocompleteOnMLXWithAFailedServerThrowsItsReasonAndLaunchesNothing() async {
        let rig = makeRig(autocomplete: .mlx)
        await rig.shared.apply(.unavailable(.notInstalled))
        XCTAssertFalse(rig.provider.isAvailable)
        XCTAssertEqual(rig.provider.unavailableReason, MLXUnavailableReason.notInstalled.message)
        do {
            _ = try await rig.provider.rewrite(RewriteRequest(selection: "x", action: .fixOnly), onPartial: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable(MLXUnavailableReason.notInstalled.message))
        }
        XCTAssertTrue(MLXRewriteStubURLProtocol.requested.isEmpty)
        XCTAssertTrue(rig.launcher.launches.isEmpty)
        XCTAssertTrue(rig.sharedLauncher.launches.isEmpty)
    }

    func test_autocompleteOnMLXWithAnIdleServerThrowsNotRunningAndLaunchesNothing() async {
        let rig = makeRig(autocomplete: .mlx)
        XCTAssertFalse(rig.provider.isAvailable)
        do {
            _ = try await rig.provider.rewrite(RewriteRequest(selection: "x", action: .fixOnly), onPartial: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable("MLX is not running."))
        }
        XCTAssertTrue(rig.launcher.launches.isEmpty)
        XCTAssertTrue(rig.sharedLauncher.launches.isEmpty)
    }

    func test_aReadyAutocompleteServerIsNotUsedWhenAutocompleteIsOnAnotherEngine() async throws {
        let rig = makeRig(autocomplete: .llamaOpenSource)
        await readyAutocompleteServer(rig, modelID: model)
        okHandler()
        async let result = rig.provider.rewrite(
            RewriteRequest(selection: "fixd", action: .fixOnly), onPartial: { _ in })
        await waitUntil { rig.probe.waiting >= 1 }
        rig.probe.succeedNext()
        _ = try await result
        XCTAssertEqual(MLXRewriteStubURLProtocol.requested, ["http://127.0.0.1:50300/v1/chat/completions"])
    }

    func test_availabilityHoldsWhenTheSharedServerIsReadyEvenIfTheOnDemandOneCannotRun() async {
        let rig = makeRig(toolchain: .notInstalled, autocomplete: .mlx)
        XCTAssertFalse(rig.provider.isAvailable)
        await readyAutocompleteServer(rig, modelID: model)
        XCTAssertTrue(rig.provider.isAvailable)
        XCTAssertNil(rig.provider.unavailableReason)
    }

    func test_a404OnTheSharedServerReportsThatServerBroken() async {
        let rig = makeRig(health: .generatorDead, autocomplete: .mlx)
        await readyAutocompleteServer(rig, modelID: model)
        MLXRewriteStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await rig.provider.rewrite(
                RewriteRequest(selection: "fixd", action: .fixOnly), onPartial: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable("MLX is restarting…"))
        }
        await waitUntil { rig.sharedLauncher.launches.count == 2 }
        XCTAssertEqual(rig.sharedLauncher.launches[0].process.terminateCount, 1)
        XCTAssertTrue(rig.launcher.launches.isEmpty)
    }

    func test_availabilityFollowsToolchainAndCache() {
        XCTAssertTrue(makeRig().provider.isAvailable)
        XCTAssertFalse(makeRig(toolchain: .notInstalled).provider.isAvailable)
        XCTAssertFalse(makeRig(cached: false).provider.isAvailable)
        XCTAssertFalse(makeRig().provider.sendsOffDevice)
    }

    func test_streamsTheRewriteFromTheServersChatRoute() async throws {
        let rig = makeRig()
        MLXRewriteStubURLProtocol.handler = { request in
            let body = try JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "mlx-community/gemma-4-e4b-it-4bit")
            let roles = (body?["messages"] as? [[String: String]])?.map { $0["role"] }
            XCTAssertEqual(roles, ["system", "user"])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "text/event-stream"])!
            return (response, Data("data: {\"choices\":[{\"delta\":{\"content\":\"Fixed text.\"}}]}\n\ndata: [DONE]\n\n".utf8))
        }
        var partials: [String] = []
        let request = RewriteRequest(selection: "fixd text", action: .fixOnly)
        async let result = rig.provider.rewrite(request, onPartial: { partials.append($0) })
        await waitUntil { rig.probe.waiting >= 1 }
        rig.probe.succeedNext()
        let text = try await result
        XCTAssertEqual(text, "Fixed text.")
        XCTAssertEqual(MLXRewriteStubURLProtocol.requested, ["http://127.0.0.1:50300/v1/chat/completions"])
        XCTAssertEqual(partials.first, "Loading MLX model…")
        XCTAssertEqual(partials.last, "Fixed text.")
    }

    private func rewrite404(health: MLXServerHealth) async -> (Rig, Error?) {
        let rig = makeRig(health: health)
        MLXRewriteStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        async let result = rig.provider.rewrite(
            RewriteRequest(selection: "fixd", action: .fixOnly), onPartial: { _ in })
        await waitUntil { rig.probe.waiting >= 1 }
        rig.probe.succeedNext()
        do {
            _ = try await result
            return (rig, nil)
        } catch {
            return (rig, error)
        }
    }

    func test_a404WithHealth503ReportsTheRewriteServerBroken() async {
        let (rig, error) = await rewrite404(health: .generatorDead)
        XCTAssertEqual(error as? RewriteError, .unavailable("MLX is restarting…"))
        await waitUntil { rig.launcher.launches.count == 2 }
        XCTAssertEqual(rig.launcher.launches[0].process.terminateCount, 1)
    }

    func test_a404WithHealthUnreachableReportsTheRewriteServerBroken() async {
        let (rig, error) = await rewrite404(health: .unreachable)
        XCTAssertEqual(error as? RewriteError, .unavailable("MLX is restarting…"))
        await waitUntil { rig.launcher.launches.count == 2 }
    }

    func test_a404WithAHealthyServerKeepsItAndFailsOnlyTheRewrite() async {
        let (rig, error) = await rewrite404(health: .healthy)
        XCTAssertEqual(error as? OpenAICompatibleClientError, .server(statusCode: 404))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(rig.launcher.launches.count, 1)
        XCTAssertEqual(rig.launcher.launches[0].process.terminateCount, 0)
    }

    func test_cancelledDuringTheHealthProbeNeverRestartsTheServer() async throws {
        let gate = HealthProbeGate()
        let rig = makeRig(healthCheck: { _ in
            gate.open()
            try? await Task.sleep(for: .seconds(10))
            return .unreachable
        })
        MLXRewriteStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let task = Task {
            try await rig.provider.rewrite(
                RewriteRequest(selection: "fixd", action: .fixOnly), onPartial: { _ in })
        }
        await waitUntil { rig.probe.waiting >= 1 }
        rig.probe.succeedNext()
        await waitUntil { gate.isOpen }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(rig.launcher.launches.count, 1)
        XCTAssertEqual(rig.launcher.launches[0].process.terminateCount, 0)
    }

    func test_unavailableServerThrowsWithoutAnyHTTPTraffic() async {
        let rig = makeRig(toolchain: .notInstalled)
        do {
            _ = try await rig.provider.rewrite(RewriteRequest(selection: "x", action: .fixOnly), onPartial: { _ in })
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? RewriteError, .unavailable(MLXUnavailableReason.notInstalled.message))
        }
        XCTAssertTrue(MLXRewriteStubURLProtocol.requested.isEmpty)
        XCTAssertTrue(rig.launcher.launches.isEmpty)
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MLXRewriteStubURLProtocol: URLProtocol {
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
