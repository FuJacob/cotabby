import XCTest
@testable import Cotabby

/// Tests for the pure rule that decides when an accepted suggestion must be committed through the
/// IME-safe insertion path. This classifier is the one piece of IME detection that does not touch
/// Carbon/TIS, so it carries the behavioral contract `KeyboardInputSourceMonitor` relies on. The
/// driving bug: with a composing IME active, the synthetic-keystroke insert is re-absorbed into
/// composition and the accept silently fails, so we detect composing input sources and switch
/// insertion methods.
final class CompositionInputModeClassifierTests: XCTestCase {
    func test_isComposingInputMode_table() {
        let cases: [(name: String, isLayout: Bool, modeID: String?, composing: Bool)] = [
            // U.S. / Dvorak / British etc. are keyboard layouts: every keystroke commits directly.
            ("plain layout", true, nil, false),
            // A layout never composes, whatever mode ID accompanies it.
            ("layout with a composing mode ID", true, "com.apple.inputmethod.Japanese.Hiragana", false),
            ("Japanese Hiragana", false, "com.apple.inputmethod.Japanese.Hiragana", true),
            ("Japanese Katakana", false, "com.apple.inputmethod.Japanese.Katakana", true),
            ("Chinese Pinyin", false, "com.apple.inputmethod.SCIM.ITABC", true),
            ("Korean", false, "com.apple.inputmethod.Korean.2SetKorean", true),
            // The shared direct-ASCII ("英数") mode of the Japanese IMEs commits per keystroke.
            ("Roman direct mode", false, "com.apple.inputmethod.Roman", false),
            // The allow-list match is exact, so a case variant falls back to the safe default.
            ("Roman case variant", false, "com.apple.inputmethod.roman", true),
            // A third-party IME (ATOK, Sogou, ...) with no recognized direct mode is assumed to
            // compose: the safe default that fixes the reported bug (the reporter uses ATOK).
            ("unknown third-party IME", false, "com.justsystems.inputmethod.atok33.Japanese", true),
            // A method-without-modes that is not a layout still composes.
            ("input method without mode ID", false, nil, true),
            ("empty mode ID", false, "", true)
        ]
        for testCase in cases {
            XCTAssertEqual(
                CompositionInputModeClassifier.isComposingInputMode(
                    isKeyboardLayout: testCase.isLayout,
                    inputModeID: testCase.modeID
                ),
                testCase.composing,
                testCase.name
            )
        }
    }
}
