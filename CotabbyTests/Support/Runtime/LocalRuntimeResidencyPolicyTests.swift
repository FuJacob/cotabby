import XCTest
@testable import Cotabby

/// Pins when the local llama runtime stays loaded. `AppDelegate` starts or stops the runtime from
/// this answer, and the Apple Intelligence fallback picker uses it to decide whether choosing a
/// model may load it, so a wrong row here costs either several GB of memory or a slow first
/// fallback suggestion.
final class LocalRuntimeResidencyPolicyTests: XCTestCase {
    func test_openSourceAlwaysKeepsTheModelLoaded() {
        for fallback in [false, true] {
            for keepLoaded in [false, true] {
                XCTAssertTrue(
                    LocalRuntimeResidencyPolicy.keepsModelLoaded(
                        engine: .llamaOpenSource,
                        isAppleLanguageFallbackEnabled: fallback,
                        keepsFallbackModelLoaded: keepLoaded
                    ),
                    "Open Source generates with the local model, so the fallback switches must not unload it"
                )
            }
        }
    }

    func test_endpointNeverKeepsTheModelLoaded() {
        for fallback in [false, true] {
            for keepLoaded in [false, true] {
                XCTAssertFalse(
                    LocalRuntimeResidencyPolicy.keepsModelLoaded(
                        engine: .openAICompatible,
                        isAppleLanguageFallbackEnabled: fallback,
                        keepsFallbackModelLoaded: keepLoaded
                    ),
                    "The endpoint runs its own model, so a resident GGUF would only duplicate memory"
                )
            }
        }
    }

    func test_appleIntelligenceKeepsTheModelLoadedOnlyWhenBothFallbackSwitchesAreOn() {
        let cases: [(fallback: Bool, keepLoaded: Bool, expected: Bool)] = [
            (false, false, false),
            (true, false, false),
            // Keep-loaded is disabled in Settings while the fallback is off, but its stored value
            // survives. It must not hold memory for a fallback that will never run.
            (false, true, false),
            (true, true, true)
        ]
        for testCase in cases {
            XCTAssertEqual(
                LocalRuntimeResidencyPolicy.keepsModelLoaded(
                    engine: .appleIntelligence,
                    isAppleLanguageFallbackEnabled: testCase.fallback,
                    keepsFallbackModelLoaded: testCase.keepLoaded
                ),
                testCase.expected,
                "fallback=\(testCase.fallback) keepLoaded=\(testCase.keepLoaded)"
            )
        }
    }
}
