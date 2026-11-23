import Foundation
import XCTest
@testable import Cotabby

/// Locks the Apple Intelligence engine's pre-generation gates. The engine must refresh
/// availability before every request and fail with Cotabby's `unavailable` vocabulary instead of
/// touching FoundationModels when the system model cannot serve it. Real generation depends on OS
/// state and is deliberately out of scope; a fake availability provider drives both gates.
@MainActor
final class FoundationModelSuggestionEngineTests: XCTestCase {

    /// Availability is re-read per request: a state that was available at launch but has since
    /// become unavailable must block generation with the fresh reason.
    func test_generation_refreshesAvailabilityAndFailsWithTheCurrentReason() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("FoundationModelSuggestionEngine requires macOS 26")
        }
        let provider = FakeFoundationModelAvailabilityProvider(
            current: .available,
            refreshResult: .unavailable("Apple Intelligence is turned off in System Settings.")
        )
        let engine = makeEngine(provider: provider)

        await assertUnavailable(engine, message: "Apple Intelligence is turned off in System Settings.")
        XCTAssertEqual(provider.refreshCount, 1)
        #else
        throw XCTSkip("FoundationModels is unavailable in this SDK")
        #endif
    }

    /// Only the system provider owns a `SystemLanguageModel`. A provider that reports available
    /// without one must produce an explicit failure rather than a session with the wrong backend.
    func test_generation_availableWithoutSystemModelFailsExplicitly() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("FoundationModelSuggestionEngine requires macOS 26")
        }
        let engine = makeEngine(provider: FakeFoundationModelAvailabilityProvider(current: .available))

        await assertUnavailable(
            engine,
            message: "Apple Intelligence reported available, but Cotabby could not access the system language model."
        )
        #else
        throw XCTSkip("FoundationModels is unavailable in this SDK")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func makeEngine(provider: FakeFoundationModelAvailabilityProvider) -> FoundationModelSuggestionEngine {
        let service = TestLifetime.retain(FoundationModelAvailabilityService(provider: provider))
        return TestLifetime.retain(FoundationModelSuggestionEngine(availabilityService: service))
    }

    @available(macOS 26.0, *)
    private func assertUnavailable(
        _ engine: FoundationModelSuggestionEngine,
        message expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await engine.generateSuggestion(for: CotabbyTestFixtures.suggestionRequest())
            XCTFail("Expected an unavailable error", file: file, line: line)
        } catch let SuggestionClientError.unavailable(message) {
            XCTAssertEqual(message, expected, file: file, line: line)
        } catch {
            XCTFail("Expected SuggestionClientError.unavailable, got \(error)", file: file, line: line)
        }
    }
    #endif
}
