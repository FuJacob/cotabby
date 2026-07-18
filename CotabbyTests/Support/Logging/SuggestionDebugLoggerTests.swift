import XCTest
@testable import Cotabby

/// Tests for `SuggestionDebugLogger`'s console block routing and formatting.
@MainActor
final class SuggestionDebugLoggerTests: XCTestCase {
    // MARK: - Instance logging paths

    /// The block formatter is a console-only sink (its output goes through
    /// `CotabbyDebugOptions.log`), so these lock the routing decisions: which stage/payload
    /// combinations emit which block kinds, and that the duplicate-line guard tolerates repeats.
    func test_logStage_routesEveryPayloadShapeWithoutCrashing() {
        let logger = SuggestionDebugLogger(colorizedOutput: true)

        logger.logStage("generating", workID: 1, generation: 2, message: "m", prompt: "PROMPT")
        logger.logStage(
            "ready",
            workID: 1,
            generation: 2,
            message: "m",
            rawOutput: "raw words",
            normalizedOutput: "normalized words"
        )
        logger.logStage("ready", workID: 1, generation: nil, message: "m", rawOutput: "raw only")
        logger.logStage("failed", workID: 1, generation: nil, message: "engine exploded")
        // Repeating the identical failure exercises the duplicate-line suppression.
        logger.logStage("failed", workID: 1, generation: nil, message: "engine exploded")
        // Stages with no model-boundary payload are deliberately not console-logged.
        logger.logStage("debouncing", workID: 1, generation: 2, message: "m")
    }

    func test_logStage_plainOutputPathHandlesUncoloredConsoles() {
        let logger = SuggestionDebugLogger(colorizedOutput: false)

        logger.logStage("generating", workID: 9, generation: 1, message: "m", prompt: "P")
        logger.logStage("failed", workID: 9, generation: 1, message: "boom")
    }

}
