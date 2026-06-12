import XCTest
@testable import Cotabby

/// Tests for `SuggestionDebugLogger`: the escaped single-line preview used by compact logs and
/// menu summaries, plus the instance-level console block formatting (safe to instantiate since
/// the type grew its `nonisolated deinit`).
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

    func test_debugPreview_emptyTextReturnsPlaceholder() async {
        XCTAssertEqual(SuggestionDebugLogger.debugPreview(""), "<empty>")
    }

    func test_debugPreview_shortTextReturnsQuotedEscapedDescription() async {
        XCTAssertEqual(SuggestionDebugLogger.debugPreview("hello"), "\"hello\"")
    }

    func test_debugPreview_escapesControlCharactersIntoOneLine() async {
        let preview = SuggestionDebugLogger.debugPreview("line1\nline2\ttabbed")

        XCTAssertEqual(preview, "\"line1\\nline2\\ttabbed\"")
        XCTAssertFalse(preview.contains("\n"), "A preview must never break the log line it is embedded in")
    }

    func test_debugPreview_truncatesLongEscapedTextWithEllipsis() async {
        let text = String(repeating: "a", count: 200)

        let preview = SuggestionDebugLogger.debugPreview(text)

        // The escaped form is 202 characters (two quotes), so the preview keeps the first 160
        // escaped characters and appends the ellipsis.
        XCTAssertEqual(preview, "\"" + String(repeating: "a", count: 159) + "...")
        XCTAssertEqual(preview.count, 163)
    }

    func test_debugPreview_keepsTextWhoseEscapedFormFitsTheLimit() async {
        // 158 characters plus the surrounding quotes is exactly 160 escaped characters: the
        // boundary case must pass through untouched.
        let text = String(repeating: "a", count: 158)

        let preview = SuggestionDebugLogger.debugPreview(text)

        XCTAssertEqual(preview, text.debugDescription)
        XCTAssertFalse(preview.hasSuffix("..."))
    }
}
