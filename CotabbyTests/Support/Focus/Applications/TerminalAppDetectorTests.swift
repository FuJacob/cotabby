import XCTest
@testable import Cotabby

/// Tests for terminal-emulator detection: the app-level bundle list, the xterm.js DOM-class check
/// that catches terminals embedded inside editors, and the availability evaluator's terminal gate.
final class TerminalAppDetectorTests: XCTestCase {

    // MARK: - Bundle identifiers

    func test_isTerminal_recognizesEveryKnownEmulator() {
        let terminals = [
            "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "io.alacritty",
            "co.zeit.hyper", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.github.wez.wezterm",
            "io.rio.terminal"
        ]
        for bundleIdentifier in terminals {
            XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: bundleIdentifier), bundleIdentifier)
        }
    }

    func test_isTerminal_rejectsNonTerminalsAndNil() {
        // VS Code hosts an integrated terminal, but the app as a whole is not one; that case is
        // handled per-field by `isIntegratedTerminal`.
        for bundleIdentifier in ["com.apple.Safari", "com.microsoft.VSCode"] {
            XCTAssertFalse(TerminalAppDetector.isTerminal(bundleIdentifier: bundleIdentifier), bundleIdentifier)
        }
        XCTAssertFalse(TerminalAppDetector.isTerminal(bundleIdentifier: nil))
    }

    func test_isTerminal_isAnExactCaseSensitiveMatch() {
        // Unlike `BrowserAppDetector`, this list is matched exactly: no case folding and no prefix
        // matching for channel suffixes.
        XCTAssertFalse(TerminalAppDetector.isTerminal(bundleIdentifier: "com.apple.terminal"))
        XCTAssertFalse(TerminalAppDetector.isTerminal(bundleIdentifier: "com.googlecode.iterm2.beta"))
    }

    // MARK: - Integrated terminal (xterm.js DOM class list)

    func test_isIntegratedTerminal_xtermHelperTextarea() {
        // The focused input leaf in a VS Code / Cursor terminal — verified live against the real
        // AX tree (role AXTextField, class "xterm-helper-textarea").
        XCTAssertTrue(TerminalAppDetector.isIntegratedTerminal(domClassList: ["xterm-helper-textarea"]))
    }

    func test_isIntegratedTerminal_xtermPrefixedSibling() {
        // Prefix match so focus landing on another xterm node (or an xterm internal rename) still
        // counts as a terminal.
        XCTAssertTrue(TerminalAppDetector.isIntegratedTerminal(domClassList: ["xterm-screen"]))
    }

    func test_isIntegratedTerminal_monacoEditor_isFalse() {
        // The VS Code code editor and Copilot chat input — must stay enabled.
        XCTAssertFalse(TerminalAppDetector.isIntegratedTerminal(domClassList: ["native-edit-context"]))
        XCTAssertFalse(
            TerminalAppDetector.isIntegratedTerminal(domClassList: ["monaco-editor", "no-user-select", "mac"])
        )
    }

    func test_isIntegratedTerminal_empty_isFalse() {
        XCTAssertFalse(TerminalAppDetector.isIntegratedTerminal(domClassList: []))
    }

    // MARK: - Evaluator integration

    private func supportedSnapshot(applicationName: String, bundleIdentifier: String) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            capability: .supported,
            context: nil
        )
    }

    func test_evaluator_blocksTerminalApp() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: supportedSnapshot(applicationName: "Terminal", bundleIdentifier: "com.apple.Terminal")
        )

        XCTAssertEqual(reason, "Cotabby is not available in terminal apps.")
    }

    func test_evaluator_doesNotBlockNonTerminalApp() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: supportedSnapshot(applicationName: "Safari", bundleIdentifier: "com.apple.Safari")
        )

        XCTAssertNil(reason)
    }

    func test_shouldSchedulePrediction_falseForTerminal() {
        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
                globallyEnabled: true,
                inputMonitoringGranted: true,
                focusSnapshot: supportedSnapshot(applicationName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2")
            )
        )
    }

    func test_globalDisabled_winsOverTerminalCheck() {
        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            inputMonitoringGranted: true,
            focusSnapshot: supportedSnapshot(applicationName: "Terminal", bundleIdentifier: "com.apple.Terminal")
        )

        XCTAssertEqual(reason, "Cotabby is turned off.",
                       "Global-off should take precedence over the terminal check")
    }
}
