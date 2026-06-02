import XCTest
@testable import Cotabby

/// Tests for the pure keystroke-vs-paste insertion policy.
///
/// The contract: paste is opt-in and reserved for long or multi-line chunks; everything else stays on
/// the default clipboard-free keystroke path, so enabling the flag never changes how short single-line
/// completions are committed.
final class InsertionStrategySelectorTests: XCTestCase {
    func test_pasteDisabled_alwaysKeystroke() {
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: "hi", pasteEnabled: false), .keystroke)
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: long, pasteEnabled: false), .keystroke)
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: "a\nb", pasteEnabled: false), .keystroke)
    }

    func test_pasteEnabled_shortSingleLineKeystrokes() {
        XCTAssertEqual(
            InsertionStrategySelector.strategy(forChunk: "a short completion", pasteEnabled: true),
            .keystroke
        )
    }

    func test_pasteEnabled_multiLinePastes() {
        XCTAssertEqual(
            InsertionStrategySelector.strategy(forChunk: "line one\nline two", pasteEnabled: true),
            .paste
        )
    }

    func test_pasteEnabled_longChunkPastes() {
        let long = String(repeating: "a", count: InsertionStrategySelector.pasteCharacterThreshold)
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: long, pasteEnabled: true), .paste)
    }

    func test_pasteEnabled_justBelowThresholdKeystrokes() {
        let nearly = String(repeating: "a", count: InsertionStrategySelector.pasteCharacterThreshold - 1)
        XCTAssertEqual(InsertionStrategySelector.strategy(forChunk: nearly, pasteEnabled: true), .keystroke)
    }
}
