import XCTest
@testable import Cotabby

/// Tests for the length-budget vocabulary in `SuggestionConfiguration.swift`: preset ranges and their
/// persisted raw values, custom-range clamping, the token-budget rounding rule, and the derived
/// llama prompt budget that must stay in lockstep with the runtime context window.
final class SuggestionConfigurationTests: XCTestCase {
    // MARK: - SuggestionWordCountPreset

    func test_wordCountPresets_rawValuesArePersistedIdentifiersInMenuOrder() {
        // Raw values are stored under `cotabbySelectedWordCountPreset`; renaming one would silently
        // reset every user who picked it back to the default preset.
        XCTAssertEqual(SuggestionWordCountPreset.allCases.map(\.rawValue), ["2-4", "4-7", "7-12", "12-20"])
        XCTAssertEqual(SuggestionWordCountPreset.twelveToTwenty.displayLabel, "12-20 words")
    }

    func test_wordCountPresets_exposeMatchingRanges() {
        XCTAssertEqual(
            SuggestionWordCountPreset.allCases.map(\.range),
            [
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
}
