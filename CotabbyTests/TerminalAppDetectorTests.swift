import XCTest
@testable import Cotabby

final class TerminalAppDetectorTests: XCTestCase {

    // MARK: - Known terminals

    func test_isTerminal_appleTerminal() {
        XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: "com.apple.Terminal"))
    }

    func test_isTerminal_iTerm2() {
        XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: "com.googlecode.iterm2"))
    }

    func test_isTerminal_kitty() {
        XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: "net.kovidgoyal.kitty"))
    }

    func test_isTerminal_alacritty() {
        XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: "io.alacritty"))
    }

    func test_isTerminal_hyper() {
        XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: "co.zeit.hyper"))
    }

    func test_isTerminal_ghostty() {
        XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: "com.mitchellh.ghostty"))
    }

    func test_isTerminal_warp() {
        XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: "dev.warp.Warp-Stable"))
    }

    func test_isTerminal_wezterm() {
        XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: "com.github.wez.wezterm"))
    }

    func test_isTerminal_rio() {
        XCTAssertTrue(TerminalAppDetector.isTerminal(bundleIdentifier: "io.rio.terminal"))
    }

    // MARK: - Non-terminals

    func test_isTerminal_safari() {
        XCTAssertFalse(TerminalAppDetector.isTerminal(bundleIdentifier: "com.apple.Safari"))
    }

    func test_isTerminal_vscode() {
        XCTAssertFalse(TerminalAppDetector.isTerminal(bundleIdentifier: "com.microsoft.VSCode"))
    }

    func test_isTerminal_nil() {
        XCTAssertFalse(TerminalAppDetector.isTerminal(bundleIdentifier: nil))
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

    func test_evaluator_blocksTerminalApp() {
        let snapshot = FocusSnapshot(
            applicationName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            capability: .supported,
            context: nil,
            inspection: nil
        )

        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: snapshot
        )

        XCTAssertEqual(reason, "Cotabby is not available in terminal apps.")
    }

    func test_evaluator_doesNotBlockNonTerminalApp() {
        let snapshot = FocusSnapshot(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            capability: .supported,
            context: nil,
            inspection: nil
        )

        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: true,
            inputMonitoringGranted: true,
            focusSnapshot: snapshot
        )

        XCTAssertNil(reason)
    }

    func test_shouldSchedulePrediction_falseForTerminal() {
        let snapshot = FocusSnapshot(
            applicationName: "iTerm2",
            bundleIdentifier: "com.googlecode.iterm2",
            capability: .supported,
            context: nil,
            inspection: nil
        )

        XCTAssertFalse(
            SuggestionAvailabilityEvaluator.shouldSchedulePrediction(
                globallyEnabled: true,
                inputMonitoringGranted: true,
                focusSnapshot: snapshot
            )
        )
    }

    func test_globalDisabled_winsOverTerminalCheck() {
        let snapshot = FocusSnapshot(
            applicationName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            capability: .supported,
            context: nil,
            inspection: nil
        )

        let reason = SuggestionAvailabilityEvaluator.disabledReason(
            globallyEnabled: false,
            inputMonitoringGranted: true,
            focusSnapshot: snapshot
        )

        XCTAssertEqual(reason, "Cotabby is turned off.",
                       "Global-off should take precedence over the terminal check")
    }
}
