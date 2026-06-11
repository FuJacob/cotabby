import XCTest
@testable import Cotabby

/// Tests for the pure rule that decides when an accepted suggestion must be committed through the
/// IME-safe insertion path. This classifier is the one piece of IME detection that does not touch
/// Carbon/TIS, so it carries the behavioral contract `KeyboardInputSourceMonitor` relies on. The
/// driving bug: with a composing IME active, the synthetic-keystroke insert is re-absorbed into
/// composition and the accept silently fails, so we detect composing input sources and switch
/// insertion methods.
final class CompositionInputModeClassifierTests: XCTestCase {
    /// U.S. / Dvorak / British etc. are keyboard layouts: every keystroke commits directly, so they
    /// never need the IME-safe path.
    func test_plainKeyboardLayout_isNotComposing() {
        XCTAssertFalse(
            CompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: true,
                inputModeID: nil
            )
        )
    }

    func test_japaneseHiragana_isComposing() {
        XCTAssertTrue(
            CompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Japanese.Hiragana"
            )
        )
    }

    func test_japaneseKatakana_isComposing() {
        XCTAssertTrue(
            CompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Japanese.Katakana"
            )
        )
    }

    func test_chinesePinyin_isComposing() {
        XCTAssertTrue(
            CompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.SCIM.ITABC"
            )
        )
    }

    func test_korean_isComposing() {
        XCTAssertTrue(
            CompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Korean.2SetKorean"
            )
        )
    }

    /// The shared direct-ASCII ("英数") mode of the Japanese IMEs commits per keystroke with no marked
    /// text, so the normal keystroke insert works there.
    func test_romanDirectMode_isNotComposing() {
        XCTAssertFalse(
            CompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.apple.inputmethod.Roman"
            )
        )
    }

    /// A third-party IME (ATOK, Sogou, ...) that is not a plain layout and exposes no recognized
    /// direct mode is assumed to compose, the safe default that fixes the reported bug (the reporter
    /// uses ATOK).
    func test_unknownInputMethod_isComposing() {
        XCTAssertTrue(
            CompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: "com.justsystems.inputmethod.atok33.Japanese"
            )
        )
    }

    /// An input method reporting no mode ID (a method-without-modes) that is not a layout still
    /// composes.
    func test_inputMethodWithoutModeID_isComposing() {
        XCTAssertTrue(
            CompositionInputModeClassifier.isComposingInputMode(
                isKeyboardLayout: false,
                inputModeID: nil
            )
        )
    }
}
