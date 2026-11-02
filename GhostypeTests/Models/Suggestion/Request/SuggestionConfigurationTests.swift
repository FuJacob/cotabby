import XCTest
@testable import Ghostype

/// Tests for the length-budget vocabulary in `SuggestionConfiguration.swift`: preset ranges and their
/// persisted raw values, custom-range clamping, the token-budget rounding rule, and the derived
/// llama prompt budget that must stay in lockstep with the runtime context window.
final class SuggestionConfigurationTests: XCTestCase {
    // MARK: - SuggestionWordCountPreset

    func test_wordCountPresets_rawValuesArePersistedIdentifiersInMenuOrder() {
        // Raw values are stored under `cotabbySelectedWordCountPreset`; renaming one would silently
        // reset every user who picked it back to the default preset.
        XCTAssertEqual(SuggestionWordCountPreset.allCases.map(\.rawValue), ["word", "2-4", "4-7", "7-12", "12-20"])
        XCTAssertEqual(SuggestionWordCountPreset.twelveToTwenty.displayLabel, "12-20 words")
        XCTAssertEqual(SuggestionWordCountPreset.currentWord.displayLabel, "Current word only")
        XCTAssertEqual(SuggestionWordCountPreset.currentWord.range.promptInstruction,
                       "Return only the rest of the word being typed.")
    }

    func test_wordCountPresets_exposeMatchingRanges() {
        XCTAssertEqual(
            SuggestionWordCountPreset.allCases.map(\.range),
            [
                SuggestionWordRange(lowWords: 1, highWords: 1, isCurrentWordOnly: true),
                SuggestionWordRange(lowWords: 2, highWords: 4),
                SuggestionWordRange(lowWords: 4, highWords: 7),
                SuggestionWordRange(lowWords: 7, highWords: 12),
                SuggestionWordRange(lowWords: 12, highWords: 20)
            ]
        )
    }

    // MARK: - SuggestionWordRange

    func test_clamped_keepsLowBelowHighAndWithinBounds() {
        let cases: [(low: Int, high: Int, expected: SuggestionWordRange, name: String)] = [
            (12, 3, SuggestionWordRange(lowWords: 12, highWords: 12), "inverted pair snaps high up to low"),
            (0, 4, SuggestionWordRange(lowWords: SuggestionWordRange.minimumWord, highWords: 4), "low below floor"),
            (10, 9_999, SuggestionWordRange(lowWords: 10, highWords: SuggestionWordRange.maximumWord), "high above ceiling"),
            (
                75,
                80,
                SuggestionWordRange(lowWords: SuggestionWordRange.maximumWord, highWords: SuggestionWordRange.maximumWord),
                "both above ceiling collapse to the ceiling"
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                SuggestionWordRange.clamped(low: testCase.low, high: testCase.high),
                testCase.expected,
                testCase.name
            )
        }
    }

    func test_wordRangeLabels_renderLowAndHighBounds() {
        let range = SuggestionWordRange(lowWords: 5, highWords: 15)

        XCTAssertEqual(range.compactLabel, "5-15 w")
        XCTAssertEqual(range.promptInstruction, "Return only the next 5 to 15 words.")
    }

    func test_predictionTokenBudget_roundsUpSoTheCapNeverUndershootsTheUpperWordBound() {
        // 7 * 1.3 = 9.1 must become 10, not truncate to 9 and clip the last word.
        XCTAssertEqual(SuggestionWordRange.predictionTokenBudget(highWords: 7, tokensPerWord: 1.3), 10)
        XCTAssertEqual(SuggestionWordRange.predictionTokenBudget(highWords: 10, tokensPerWord: 2.0), 20)
    }

    // MARK: - SuggestionConfiguration

    func test_derivedLlamaPromptTokenBudget_subtractsOutputCeilingAndSafetyMarginFromContextWindow() {
        let expected = Int(LlamaRuntimeConfiguration.default.contextWindowTokens)
            - SuggestionConfiguration.llamaPromptOutputCeilingTokens
            - SuggestionConfiguration.llamaPromptSafetyMarginTokens

        XCTAssertEqual(SuggestionConfiguration.derivedLlamaPromptTokenBudget, expected)
        // The shipped configuration must use the derived value, not a stale literal.
        XCTAssertEqual(SuggestionConfiguration.standard.llamaPromptTokenBudget, expected)
    }

    // MARK: - LatencyAutoTuner

    func test_autoTuner_keepsCurrentStateWithTooFewSamples() {
        var tuner = LatencyAutoTuner()
        // One slow outlier must not flip the setting on a cold start.
        tuner.record(latencyMs: 2000)
        XCTAssertFalse(tuner.shouldUseShortContext(current: false))
        tuner.record(latencyMs: 2000)
        XCTAssertFalse(tuner.shouldUseShortContext(current: false))
    }

    func test_autoTuner_enablesShortContextWhenMedianIsSlow() {
        var tuner = LatencyAutoTuner()
        tuner.record(latencyMs: 900)
        tuner.record(latencyMs: 1200)
        tuner.record(latencyMs: 1000)
        XCTAssertTrue(tuner.shouldUseShortContext(current: false))
    }

    func test_autoTuner_disablesShortContextWhenMedianIsFast() {
        var tuner = LatencyAutoTuner()
        tuner.record(latencyMs: 150)
        tuner.record(latencyMs: 200)
        tuner.record(latencyMs: 180)
        XCTAssertFalse(tuner.shouldUseShortContext(current: true))
    }

    func test_autoTuner_hysteresisKeepsStateInTheMiddleBand() {
        var tuner = LatencyAutoTuner()
        // Median 500ms is between the 300ms disable and 800ms enable thresholds:
        // the setting sticks instead of flip-flopping.
        tuner.record(latencyMs: 480)
        tuner.record(latencyMs: 520)
        tuner.record(latencyMs: 500)
        XCTAssertTrue(tuner.shouldUseShortContext(current: true))
        XCTAssertFalse(tuner.shouldUseShortContext(current: false))
    }

    func test_autoTuner_medianIgnoresOneSlowOutlier() {
        var tuner = LatencyAutoTuner()
        tuner.record(latencyMs: 150)
        tuner.record(latencyMs: 180)
        tuner.record(latencyMs: 5000)
        // Sorted [150, 180, 5000], median 180 → fast, outlier ignored.
        XCTAssertFalse(tuner.shouldUseShortContext(current: false))
    }

    func test_speedSettings_autoTuneOverridesManualToggle() {
        let defaults = UserDefaults(suiteName: "test-speed-auto-tune")!
        defaults.removePersistentDomain(forName: "test-speed-auto-tune")
        defaults.set(true, forKey: SpeedSettings.autoTuneKey)
        defaults.set(false, forKey: SpeedSettings.shortContextKey)

        var tuner = LatencyAutoTuner()
        tuner.record(latencyMs: 1000)
        tuner.record(latencyMs: 1100)
        tuner.record(latencyMs: 900)
        // Manual toggle is OFF, but auto-tune sees slow latency → short context ON.
        let config = SpeedSettings.applied(to: .standard, defaults: defaults, autoTuner: tuner)
        XCTAssertEqual(config.maxPrefixCharacters, SpeedSettings.shortPrefixCharacters)
    }

    func test_speedSettings_manualToggleWinsWhenAutoTuneIsOff() {
        let defaults = UserDefaults(suiteName: "test-speed-manual")!
        defaults.removePersistentDomain(forName: "test-speed-manual")
        defaults.set(false, forKey: SpeedSettings.autoTuneKey)
        defaults.set(true, forKey: SpeedSettings.shortContextKey)

        var tuner = LatencyAutoTuner()
        tuner.record(latencyMs: 100)
        tuner.record(latencyMs: 120)
        tuner.record(latencyMs: 110)
        // Auto-tune is OFF, manual toggle is ON → short context stays ON despite fast latency.
        let config = SpeedSettings.applied(to: .standard, defaults: defaults, autoTuner: tuner)
        XCTAssertEqual(config.maxPrefixCharacters, SpeedSettings.shortPrefixCharacters)
    }

    func test_speedSettings_capsDefaultToTodayAndClampEntries() {
        let defaults = UserDefaults(suiteName: "test-speed-caps")!
        defaults.removePersistentDomain(forName: "test-speed-caps")
        let budget = SuggestionConfiguration.derivedLlamaPromptTokenBudget

        var config = SpeedSettings.applied(to: .standard, defaults: defaults)
        XCTAssertEqual(config.maxScreenCharacters, 4000)
        XCTAssertEqual(config.llamaPromptTokenBudget, budget)

        defaults.set(1000, forKey: SpeedSettings.screenCharactersKey)
        defaults.set(700, forKey: SpeedSettings.promptTokensKey)
        config = SpeedSettings.applied(to: .standard, defaults: defaults)
        XCTAssertEqual(config.maxScreenCharacters, 1000)
        XCTAssertEqual(config.llamaPromptTokenBudget, 700)

        // Out of range: clamped, and the prompt cap can never exceed what the model holds.
        defaults.set(-5, forKey: SpeedSettings.screenCharactersKey)
        defaults.set(99_999, forKey: SpeedSettings.promptTokensKey)
        config = SpeedSettings.applied(to: .standard, defaults: defaults)
        XCTAssertEqual(config.maxScreenCharacters, 0)
        XCTAssertEqual(config.llamaPromptTokenBudget, budget)
    }

    func test_speedSettings_hintsNameTheTradeoff() {
        XCTAssertTrue(SpeedSettings.screenCharactersHint(4000).hasPrefix("High"))
        XCTAssertTrue(SpeedSettings.screenCharactersHint(2000).hasPrefix("Medium"))
        XCTAssertTrue(SpeedSettings.screenCharactersHint(1000).hasPrefix("Low"))
        XCTAssertTrue(SpeedSettings.screenCharactersHint(0).hasPrefix("Off"))
        XCTAssertTrue(SpeedSettings.promptTokensHint(1900).hasPrefix("High"))
        XCTAssertTrue(SpeedSettings.promptTokensHint(1000).hasPrefix("Medium"))
        XCTAssertTrue(SpeedSettings.promptTokensHint(700).hasPrefix("Low"))
    }
}
