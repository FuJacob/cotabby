import XCTest
@testable import Cotabby

/// Pure tests for latency-keyed debounce. Each tier is pinned at both edges so a threshold edit is
/// always deliberate: the tiers trade time-to-first-suggestion against piling doomed generations
/// onto a model that cannot keep up.
final class DebouncePolicyTests: XCTestCase {
    private func assertDebounce(
        _ cases: [(latency: Int?, expected: Int)],
        fallback: Int,
        engine: SuggestionEngineKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for testCase in cases {
            XCTAssertEqual(
                DebouncePolicy.milliseconds(
                    lastGenerationLatencyMilliseconds: testCase.latency,
                    fallback: fallback,
                    engine: engine
                ),
                testCase.expected,
                "\(engine) latency \(String(describing: testCase.latency)) fallback \(fallback)",
                file: file,
                line: line
            )
        }
    }

    /// In-process engines use the configured fallback until a real (positive) latency exists.
    func test_localEngines_tiersAndFallback() {
        let cases: [(latency: Int?, expected: Int)] = [
            (nil, 20), (0, 20), (-5, 20),
            (1, 15), (70, 15),
            (71, 25), (140, 25),
            (141, 55), (900, 55)
        ]
        assertDebounce(cases, fallback: 20, engine: .llamaOpenSource)
        // Apple Intelligence runs on-device too and shares the local tiers.
        assertDebounce(cases, fallback: 20, engine: .appleIntelligence)
    }

    func test_defaultEngineIsLocal() {
        XCTAssertEqual(DebouncePolicy.milliseconds(lastGenerationLatencyMilliseconds: 45, fallback: 20), 15)
    }

    /// An HTTP endpoint cannot reuse the in-process KV cache and may not stop work on cancel, so it
    /// always uses a longer trailing-edge pause that collapses a typing burst into one request.
    func test_endpoint_tiersAndFallbackFloor() {
        assertDebounce(
            [
                (nil, 180), (0, 180), (-5, 180),
                (1, 100), (300, 100),
                (301, 150), (700, 150),
                (701, 220), (1_000, 220)
            ],
            fallback: 20,
            engine: .openAICompatible
        )
        // Without a latency, a configured fallback above the 180 ms floor wins.
        assertDebounce([(nil, 250)], fallback: 250, engine: .openAICompatible)
    }
}
