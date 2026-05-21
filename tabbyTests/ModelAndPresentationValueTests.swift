import AppKit
import XCTest
@testable import tabby

/// Tests for compact value-model behavior used directly by menu and overlay UI.
///
/// These are intentionally small, but they protect user-facing copy and normalization rules that
/// would otherwise regress quietly during UI refactors.
final class SuggestionTextColorCodecTests: XCTestCase {
    func test_nsColorFromHex_decodesSixDigitRGB() {
        let color = SuggestionTextColorCodec.nsColor(fromHex: "336699")?.usingColorSpace(.sRGB)

        XCTAssertNotNil(color)
        XCTAssertEqual(color?.redComponent ?? 0, CGFloat(0x33) / 255, accuracy: 0.001)
        XCTAssertEqual(color?.greenComponent ?? 0, CGFloat(0x66) / 255, accuracy: 0.001)
        XCTAssertEqual(color?.blueComponent ?? 0, CGFloat(0x99) / 255, accuracy: 0.001)
        XCTAssertEqual(color?.alphaComponent ?? 0, 1, accuracy: 0.001)
    }

    func test_nsColorFromHex_rejectsMalformedValues() {
        XCTAssertNil(SuggestionTextColorCodec.nsColor(fromHex: nil))
        XCTAssertNil(SuggestionTextColorCodec.nsColor(fromHex: "12345"))
        XCTAssertNil(SuggestionTextColorCodec.nsColor(fromHex: "1234567"))
        XCTAssertNil(SuggestionTextColorCodec.nsColor(fromHex: "#336699"))
        XCTAssertNil(SuggestionTextColorCodec.nsColor(fromHex: "GG6699"))
    }

    func test_hexStringFromNSColor_roundsToUppercaseSixDigitRGB() {
        let color = NSColor(
            srgbRed: CGFloat(0x12) / 255,
            green: CGFloat(0xAB) / 255,
            blue: CGFloat(0xF0) / 255,
            alpha: 0.5
        )

        XCTAssertEqual(SuggestionTextColorCodec.hexString(from: color), "12ABF0")
    }
}

final class SuggestionModelValueTests: XCTestCase {
    func test_wordCountPresetsExposeMatchingPromptInstructionsAndTokenBudgets() {
        XCTAssertEqual(SuggestionWordCountPreset.threeToSeven.promptInstruction, "Return only the next 3 to 7 words.")
        XCTAssertEqual(SuggestionWordCountPreset.threeToSeven.suggestedPredictionTokenBudget, 11)

        XCTAssertEqual(SuggestionWordCountPreset.sevenToTwelve.promptInstruction, "Return only the next 7 to 12 words.")
        XCTAssertEqual(SuggestionWordCountPreset.sevenToTwelve.suggestedPredictionTokenBudget, 18)

        XCTAssertEqual(SuggestionWordCountPreset.twelveToTwenty.promptInstruction, "Return only the next 12 to 20 words.")
        XCTAssertEqual(SuggestionWordCountPreset.twelveToTwenty.suggestedPredictionTokenBudget, 30)
    }

    func test_activeSuggestionSession_clampsConsumedCountAndSlicesByCharacters() {
        let session = TabbyTestFixtures.activeSession(
            fullText: "hello",
            consumedCharacterCount: 99
        )

        XCTAssertEqual(session.acceptedText, "hello")
        XCTAssertEqual(session.remainingText, "")
        XCTAssertTrue(session.isExhausted)
    }

    func test_overlayStateDetailIncludesTextCountCaretPositionAndQuality() {
        let state = OverlayState.visible(
            text: "hello",
            geometry: TabbyTestFixtures.overlayGeometry(
                caretRect: CGRect(x: 12.9, y: 40.1, width: 2, height: 18),
                caretQuality: .derived
            )
        )

        XCTAssertEqual(state.shortLabel, "Visible")
        XCTAssertEqual(
            state.detail,
            "Showing 5 characters near (12, 40) using derived caret geometry."
        )
        XCTAssertEqual(state.visibleText, "hello")
    }

    func test_ghostSuggestionLayoutWrapsOverflowToInputLeftEdge() {
        let geometry = TabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 190, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 100, y: 70, width: 140, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: " alpha beta gamma delta",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertGreaterThan(layout.lines.count, 1)
        XCTAssertEqual(layout.panelOriginX, 108)
        XCTAssertEqual(layout.lines.last?.leadingIndent, 0)
        XCTAssertEqual(layout.lines.last?.showsKeycap, true)
    }

    func test_ghostSuggestionLayoutUsesNextLineWhenCaretHasNoUsefulSpace() {
        let geometry = TabbyTestFixtures.overlayGeometry(
            caretRect: CGRect(x: 232, y: 80, width: 2, height: 18),
            inputFrameRect: CGRect(x: 100, y: 70, width: 140, height: 30),
            observedCharWidth: 7
        )

        let layout = GhostSuggestionLayout.make(
            text: " next words",
            geometry: geometry,
            fontSize: 14,
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 300)
        )

        XCTAssertEqual(layout.lines.first?.leadingIndent, 0)
        XCTAssertLessThan(layout.topLineCenterOffsetFromCaret, 0)
    }

    func test_suggestionDebugStateLabelsAndDetailsAreStable() {
        XCTAssertEqual(SuggestionDebugState.idle.shortLabel, "Idle")
        XCTAssertEqual(SuggestionDebugState.disabled("No permission").shortLabel, "Disabled")
        XCTAssertEqual(SuggestionDebugState.failed("Runtime failed").detail, "Runtime failed")
        XCTAssertEqual(SuggestionDebugState.ready(text: "hello", latency: 0.2).shortLabel, "Ready")
    }
}

final class RuntimeAndInputModelValueTests: XCTestCase {
    func test_modelDownloadStateProgressFractionIsClamped() {
        XCTAssertEqual(ModelDownloadState.downloading(progress: -0.5).progressFraction, 0)
        XCTAssertEqual(ModelDownloadState.downloading(progress: 0.42).progressFraction, 0.42)
        XCTAssertEqual(ModelDownloadState.downloading(progress: 1.5).progressFraction, 1)
        XCTAssertNil(ModelDownloadState.downloading(progress: nil).progressFraction)
        XCTAssertNil(ModelDownloadState.idle.progressFraction)
    }

    func test_modelDownloadStateStatusTextUsesRoundedPercent() {
        XCTAssertEqual(ModelDownloadState.idle.statusText, "Not installed")
        XCTAssertEqual(ModelDownloadState.downloading(progress: nil).statusText, "Downloading")
        XCTAssertEqual(ModelDownloadState.downloading(progress: 0.426).statusText, "Downloading 43%")
        XCTAssertEqual(ModelDownloadState.downloaded.statusText, "Installed")
        XCTAssertEqual(ModelDownloadState.failed("Network failed").statusText, "Network failed")
    }

    func test_runtimeModelCatalogMapsKnownNamesAndLeavesCustomNamesAlone() {
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "Qwen3.5-0.8B-Q4_K_M.gguf"),
            "tabby-fast"
        )
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "gemma-4-E2B-it-Q4_K_M.gguf"),
            "tabby-quality"
        )
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "custom-local-model.gguf"),
            "custom-local-model.gguf"
        )
    }

    func test_capturedInputEventComputedPropertiesReflectSchedulingPolicy() {
        XCTAssertTrue(TabbyTestFixtures.inputEvent(kind: .textMutation).shouldSchedulePrediction)
        XCTAssertTrue(TabbyTestFixtures.inputEvent(kind: .shortcutMutation).shouldSchedulePrediction)
        XCTAssertFalse(TabbyTestFixtures.inputEvent(kind: .navigation).shouldSchedulePrediction)

        XCTAssertTrue(TabbyTestFixtures.inputEvent(kind: .dismissal).shouldClearSuggestion)
        XCTAssertFalse(TabbyTestFixtures.inputEvent(kind: .tab).shouldClearSuggestion)
        XCTAssertFalse(TabbyTestFixtures.inputEvent(kind: .other).shouldClearSuggestion)
    }
}
