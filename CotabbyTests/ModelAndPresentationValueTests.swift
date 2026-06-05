import AppKit
import XCTest
@testable import Cotabby

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
        // Budgets are now derived from upper word count * fallback (English) tokens-per-word, rounded
        // up. Per-language scaling lives in SuggestionRequestFactory and is exercised separately.
        XCTAssertEqual(SuggestionWordCountPreset.twoToFour.promptInstruction, "Return only the next 2 to 4 words.")
        XCTAssertEqual(SuggestionWordCountPreset.twoToFour.suggestedPredictionTokenBudget, 6)

        XCTAssertEqual(SuggestionWordCountPreset.fourToSeven.promptInstruction, "Return only the next 4 to 7 words.")
        XCTAssertEqual(SuggestionWordCountPreset.fourToSeven.suggestedPredictionTokenBudget, 10)

        XCTAssertEqual(SuggestionWordCountPreset.sevenToTwelve.promptInstruction, "Return only the next 7 to 12 words.")
        XCTAssertEqual(SuggestionWordCountPreset.sevenToTwelve.suggestedPredictionTokenBudget, 16)

        XCTAssertEqual(SuggestionWordCountPreset.twelveToTwenty.promptInstruction, "Return only the next 12 to 20 words.")
        XCTAssertEqual(SuggestionWordCountPreset.twelveToTwenty.suggestedPredictionTokenBudget, 26)
    }

    func test_languageCatalog_effectiveTokensPerWord_fallsBackToEnglishForMultiOrUnknown() {
        XCTAssertEqual(LanguageCatalog.effectiveTokensPerWord(for: []), LanguageCatalog.fallbackTokensPerWord)
        XCTAssertEqual(LanguageCatalog.effectiveTokensPerWord(for: ["German"]), 1.7)
        XCTAssertEqual(LanguageCatalog.effectiveTokensPerWord(for: ["english"]), 1.3)
        // Multi-language users get the safe English ratio so we don't have to guess which one wins.
        XCTAssertEqual(
            LanguageCatalog.effectiveTokensPerWord(for: ["German", "Spanish"]),
            LanguageCatalog.fallbackTokensPerWord
        )
        // Free-text languages we don't have factors for also fall back, instead of crashing or zero.
        XCTAssertEqual(
            LanguageCatalog.effectiveTokensPerWord(for: ["Klingon"]),
            LanguageCatalog.fallbackTokensPerWord
        )
    }

    func test_suggestionWordRange_clampedKeepsLowBelowHighAndWithinBounds() {
        let inverted = SuggestionWordRange.clamped(low: 12, high: 3)
        XCTAssertEqual(inverted.lowWords, 12)
        XCTAssertEqual(inverted.highWords, 12)

        let belowFloor = SuggestionWordRange.clamped(low: 0, high: 4)
        XCTAssertEqual(belowFloor.lowWords, SuggestionWordRange.minimumWord)
        XCTAssertEqual(belowFloor.highWords, 4)

        let aboveCeiling = SuggestionWordRange.clamped(low: 10, high: 9999)
        XCTAssertEqual(aboveCeiling.lowWords, 10)
        XCTAssertEqual(aboveCeiling.highWords, SuggestionWordRange.maximumWord)
    }

    func test_activeSuggestionSession_clampsConsumedCountAndSlicesByCharacters() {
        let session = CotabbyTestFixtures.activeSession(
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
            geometry: CotabbyTestFixtures.overlayGeometry(
                caretRect: CGRect(x: 12.9, y: 40.1, width: 2, height: 18),
                caretQuality: .derived
            ),
            mode: .inline
        )

        XCTAssertEqual(state.shortLabel, "Visible")
        XCTAssertEqual(
            state.detail,
            "Showing 5 characters near (12, 40) using derived caret geometry (inline)."
        )
        XCTAssertEqual(state.visibleText, "hello")
        XCTAssertEqual(state.visibleMode, .inline)
    }

    func test_ghostSuggestionLayoutWrapsOverflowToInputLeftEdge() {
        let geometry = CotabbyTestFixtures.overlayGeometry(
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
        let geometry = CotabbyTestFixtures.overlayGeometry(
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
            RuntimeModelCatalog.displayName(for: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf"),
            "tabby-2-nano"
        )
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "Qwen3.5-2B-Base.i1-Q4_K_M.gguf"),
            "tabby-2-mini"
        )
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "gemma-4-E2B.i1-Q6_K.gguf"),
            "tabby-2-base"
        )
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "gemma-4-E4B.i1-Q4_K_M.gguf"),
            "tabby-2-pro"
        )
        // Retired models fall back to their raw filename like any unknown local GGUF. The 4B Qwen
        // base was dropped when the catalog moved to the nano/mini/base/pro four-tier lineup.
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "Qwen3.5-4B-Base.i1-Q4_K_M.gguf"),
            "Qwen3.5-4B-Base.i1-Q4_K_M.gguf"
        )
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "Qwen3.5-0.8B-Q4_K_M.gguf"),
            "Qwen3.5-0.8B-Q4_K_M.gguf"
        )
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "gemma-3-1b-it-Q4_K_M.gguf"),
            "gemma-3-1b-it-Q4_K_M.gguf"
        )
        XCTAssertEqual(
            RuntimeModelCatalog.displayName(for: "custom-local-model.gguf"),
            "custom-local-model.gguf"
        )
    }

    func test_capturedInputEventComputedPropertiesReflectSchedulingPolicy() {
        XCTAssertTrue(CotabbyTestFixtures.inputEvent(kind: .textMutation).shouldSchedulePrediction)
        XCTAssertTrue(CotabbyTestFixtures.inputEvent(kind: .shortcutMutation).shouldSchedulePrediction)
        XCTAssertFalse(CotabbyTestFixtures.inputEvent(kind: .navigation).shouldSchedulePrediction)

        XCTAssertTrue(CotabbyTestFixtures.inputEvent(kind: .dismissal).shouldClearSuggestion)
        XCTAssertFalse(CotabbyTestFixtures.inputEvent(kind: .acceptance).shouldClearSuggestion)
        XCTAssertFalse(CotabbyTestFixtures.inputEvent(kind: .fullAcceptance).shouldClearSuggestion)
        XCTAssertFalse(CotabbyTestFixtures.inputEvent(kind: .fullAcceptance).shouldSchedulePrediction)
        XCTAssertFalse(CotabbyTestFixtures.inputEvent(kind: .other).shouldClearSuggestion)
    }
}

final class GhostTextColorPresetTests: XCTestCase {
    func test_matching_nilHexResolvesToAutomatic() {
        XCTAssertEqual(GhostTextColorPreset.matching(hex: nil), .automatic)
    }

    func test_matching_isCaseInsensitiveAndIgnoresWhitespace() {
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "  3b82f6 ").id, "blue")
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "EC4899").id, "pink")
    }

    func test_matching_unknownHexFallsBackToAutomatic() {
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "010203"), .automatic)
    }

    func test_allPresetHexesAreValidAndDecodable() {
        for preset in GhostTextColorPreset.all where preset.hex != nil {
            XCTAssertNotNil(
                SuggestionTextColorCodec.nsColor(fromHex: preset.hex),
                "Preset \(preset.id) has an undecodable hex"
            )
        }
    }
}

final class GhostTextOpacitySettingsTests: XCTestCase {
    /// Hosted macOS tests crash while deallocating short-lived `SuggestionSettingsModel` instances,
    /// so we retain them for the process lifetime and drive each test through `MainActor`. This
    /// mirrors `SuggestionSettingsModelDisabledAppsTests`, which quarantines the same runtime issue.
    private static var retainedModels: [SuggestionSettingsModel] = []

    private var userDefaultsSuites: [(suiteName: String, userDefaults: UserDefaults)] = []

    override func tearDown() {
        for suite in userDefaultsSuites {
            suite.userDefaults.removePersistentDomain(forName: suite.suiteName)
        }
        userDefaultsSuites.removeAll()
        super.tearDown()
    }

    func test_defaultOpacityIsFullyOpaqueOnFreshInstall() {
        runOnMainActor {
            XCTAssertEqual(makeModel().ghostTextOpacity, SuggestionSettingsModel.defaultGhostTextOpacity)
        }
    }

    func test_setOpacityClampsBelowMinimumAndAboveMaximum() {
        runOnMainActor {
            let model = makeModel()

            model.setGhostTextOpacity(0.0)
            XCTAssertEqual(model.ghostTextOpacity, SuggestionSettingsModel.minimumGhostTextOpacity)

            model.setGhostTextOpacity(5.0)
            XCTAssertEqual(model.ghostTextOpacity, SuggestionSettingsModel.maximumGhostTextOpacity)
        }
    }

    func test_opacityPersistsAcrossModelReload() {
        runOnMainActor {
            let userDefaults = makeUserDefaults()
            makeModel(userDefaults: userDefaults).setGhostTextOpacity(0.5)

            XCTAssertEqual(makeModel(userDefaults: userDefaults).ghostTextOpacity, 0.5)
        }
    }

    @MainActor
    private func makeModel(userDefaults: UserDefaults? = nil) -> SuggestionSettingsModel {
        let model = SuggestionSettingsModel(
            configuration: .standard,
            userDefaults: userDefaults ?? makeUserDefaults()
        )
        Self.retainedModels.append(model)
        return model
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "GhostTextOpacitySettingsTests-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected an isolated UserDefaults suite")
            return .standard
        }

        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaultsSuites.append((suiteName: suiteName, userDefaults: userDefaults))
        return userDefaults
    }

    private func runOnMainActor<Result>(
        _ body: @MainActor () throws -> Result
    ) rethrows -> Result {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(body)
        }

        return try DispatchQueue.main.sync {
            try MainActor.assumeIsolated(body)
        }
    }
}
