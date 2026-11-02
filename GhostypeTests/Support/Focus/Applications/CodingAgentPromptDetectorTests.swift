import XCTest
@testable import Ghostype

/// Tests for the terminal coding-agent prompt rule. Each case is the text a terminal's
/// Accessibility text area exposes, split at the caret (`|` in the comments). The rule must find
/// the agent's typed request and must never fire on a shell prompt.
final class CodingAgentPromptDetectorTests: XCTestCase {
    private func detect(_ preceding: String, _ trailing: String, title: String? = nil) -> CodingAgentPromptDetector.AgentInput? {
        CodingAgentPromptDetector.agentInput(precedingText: preceding, trailingText: trailing, windowTitle: title)
    }

    // MARK: - Agents

    func test_claudeCodeRoundedBox() {
        // ╭───╮ / │ > fix the fla|   │ / ╰───╯
        let input = detect(
            "⏺ Done.\n\n╭──────────────────────╮\n│ > fix the fla",
            "                │\n╰──────────────────────╯\n  ? for shortcuts"
        )
        XCTAssertEqual(input, .init(precedingText: "fix the fla", trailingText: ""))
    }

    func test_claudeCodeRuledPrompt_keepsTextAfterTheCaret() {
        // ──── / > rename the| helper / ────
        let input = detect("some output\n────────────────\n> rename the", " helper\n────────────────\n  ⏵⏵ accept edits on")
        XCTAssertEqual(input, .init(precedingText: "rename the", trailingText: " helper"))
    }

    func test_copilotChevronInsideZellijPaneBorders() {
        let input = detect("│╭────────────╮│\n││ ❯ add tests", "    ││\n│╰────────────╯│")
        XCTAssertEqual(input, .init(precedingText: "add tests", trailingText: ""))
    }

    func test_emptyAgentPrompt_isStillAnAgentPrompt() {
        XCTAssertEqual(detect("────\n> ", "\n────"), .init(precedingText: "", trailingText: ""))
    }

    func test_codexComposer_needsTheTitle() {
        let preceding = "• Ran tests\n\n› explain this"
        let trailing = "\n\n  100% context left"
        XCTAssertEqual(detect(preceding, trailing, title: "repo — codex — 120×40"),
                       .init(precedingText: "explain this", trailingText: ""))
        XCTAssertNil(detect(preceding, trailing))
        XCTAssertNil(detect(preceding, trailing, title: "codexity — zsh"))
    }

    // MARK: - Shells and other near misses

    func test_starshipOrPurePrompt_isNotAnAgent() {
        XCTAssertNil(detect("~/code/repo on main\n❯ git sta", ""))
    }

    func test_promptDirectlyBelowATmuxDivider_isNotAnAgent() {
        // A horizontal tmux split puts a rule above the lower pane's first line, but nothing below.
        XCTAssertNil(detect("left pane output\n────────────────\n❯ ls", "\nmore"))
    }

    func test_bashContinuationPrompt_isNotAnAgent() {
        XCTAssertNil(detect("$ cat <<EOF\n> hello", ""))
    }

    func test_redirectOrArrowWithoutSpace_isNotAPrompt() {
        XCTAssertNil(detect("────\n>foo", "\n────"))
        XCTAssertNil(detect("────\n->x", "\n────"))
    }

    func test_codexTitleDoesNotOpenAChevronShellPrompt() {
        // The title fallback is only for Codex's own `›` marker.
        XCTAssertNil(detect("~/codex\n❯ ls", "", title: "codex"))
    }

    func test_emptyBoxLineIsNotARule() {
        XCTAssertNil(detect("│      │\n│ > hi", "   │\n│      │"))
    }

    func test_caretOnAWrappedSecondLine_isAMiss() {
        XCTAssertNil(detect("╭──────╮\n│ > first line of a\n│   long request", "  │\n╰──────╯"))
    }
}

/// Tests for telling VS Code's code editor apart from its chat and commit inputs.
final class CodeEditorSurfaceDetectorTests: XCTestCase {
    func test_monacoInputClasses() {
        XCTAssertTrue(CodeEditorSurfaceDetector.isMonacoInput(domClassList: ["native-edit-context"]))
        XCTAssertTrue(CodeEditorSurfaceDetector.isMonacoInput(domClassList: ["inputarea", "monaco-mouse-cursor-text"]))
        XCTAssertFalse(CodeEditorSurfaceDetector.isMonacoInput(domClassList: ["xterm-helper-textarea"]))
        XCTAssertFalse(CodeEditorSurfaceDetector.isMonacoInput(domClassList: []))
    }

    func test_editorPaneAncestor() {
        let editor = [["overflow-guard"], ["monaco-editor", "vs-dark"], ["editor-container"], ["editor-instance"]]
        let chat = [["overflow-guard"], ["monaco-editor"], ["interactive-input-editor"], ["interactive-input-part"]]
        XCTAssertTrue(CodeEditorSurfaceDetector.isInsideEditorPane(ancestorClassLists: editor))
        XCTAssertFalse(CodeEditorSurfaceDetector.isInsideEditorPane(ancestorClassLists: chat))
    }
}
