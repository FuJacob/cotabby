import Foundation

/// Recognizes the input box of an AI coding agent (Claude Code, GitHub Copilot CLI, Codex, pi, …)
/// drawn inside a terminal, and cuts the terminal's text down to what the user typed into it.
///
/// Why it exists: a terminal exposes its whole scrollback as one Accessibility text area with the
/// caret at the cursor, so without this rule Ghostype could only treat every terminal as one giant,
/// shell-shaped field (which is why terminals are blocked by default). Coding agents are the one
/// terminal surface where prose completion helps: the user is writing a request to a model. This
/// pure rule decides, from the text around the caret alone, whether the caret sits in such a box,
/// and if so hands the pipeline only the typed request instead of the scrollback.
///
/// The rule is deliberately conservative, because a ghost in a shell prompt is worse than a miss:
/// - The caret's line must start (after any pane/box borders) with an agent prompt marker:
///   `>` or `❯` (Claude Code, Copilot CLI) or `›` (Codex).
/// - And the box must be confirmed: either the lines directly above and below the caret line are
///   horizontal box rules (`────`, `╭──╮`/`╰──╯`), which is how Claude Code and Copilot CLI frame
///   their input and what no shell prompt draws, or, for Codex's unframed `›` composer, the window
///   title names `codex` (Terminal.app, iTerm2 and tmux put the running command in the title).
///
/// Only a single-line request is recognized: when the caret is on a wrapped or second line of the
/// request, its line carries no marker and the rule declines.
///
/// Called by `FocusSnapshotResolver` for terminal apps and integrated terminals; the availability
/// gate reads the resulting `FocusedInputSnapshot.isCodingAgentPrompt` flag.
nonisolated enum CodingAgentPromptDetector {
    /// The typed request split at the caret, in the coordinates the pipeline expects.
    struct AgentInput: Equatable {
        let precedingText: String
        let trailingText: String
    }

    /// Characters a pane or box draws at the edges of a line: tmux/zellij pane borders and the
    /// sides of an agent's rounded box. Stripped before looking for the prompt marker.
    private static let edgeCharacters: Set<Character> = ["│", "┃", "║", "▌", " ", "\u{00A0}"]
    private static let framedMarkers: Set<Character> = [">", "❯", "›"]
    private static let codexMarker: Character = "›"

    static func agentInput(precedingText: String, trailingText: String, windowTitle: String?) -> AgentInput? {
        // `Character.isNewline` also covers "\r\n", which is a single Character in Swift.
        let linesBefore = precedingText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let linesAfter = trailingText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let caretLineHead = linesBefore.last else { return nil }

        let afterEdges = caretLineHead.drop { edgeCharacters.contains($0) }
        guard let marker = afterEdges.first, framedMarkers.contains(marker) else { return nil }
        let rest = afterEdges.dropFirst()
        // "> " followed by the request, or a bare marker with the caret right after it. A marker
        // glued to text (">foo", "->") is shell output or a redirect, not a prompt.
        guard rest.isEmpty || rest.first == " " else { return nil }

        let isFramed = linesBefore.dropLast().last.map(isHorizontalRule) == true
            && linesAfter.dropFirst().first.map(isHorizontalRule) == true
        let isTitledCodex = marker == codexMarker && titleNamesCodex(windowTitle)
        guard isFramed || isTitledCodex else { return nil }

        return AgentInput(
            precedingText: String(rest.drop { $0 == " " }),
            trailingText: trimmingTrailingEdges(linesAfter.first ?? "")
        )
    }

    /// A line made only of box-drawing characters (U+2500–U+257F) and spaces, with at least three
    /// horizontal strokes: `────`, `╭────╮`, `╰────╯`, also inside pane borders (`│╭──╮│`). A row of
    /// bare vertical borders (an empty box line) is not a rule.
    private static func isHorizontalRule(_ line: Substring) -> Bool {
        let scalars = line.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        let horizontalStrokes = scalars.filter { "─━═".unicodeScalars.contains($0) }.count
        return horizontalStrokes >= 3 && scalars.allSatisfy { (0x2500...0x257F).contains($0.value) }
    }

    /// Drops the right-hand box side and the padding before it, keeping text typed after the caret.
    private static func trimmingTrailingEdges(_ line: Substring) -> String {
        var tail = line
        while let last = tail.last, edgeCharacters.contains(last) {
            tail = tail.dropLast()
        }
        return String(tail)
    }

    /// Whether the window title contains `codex` as its own word ("codex", "node — codex — 80×24",
    /// "main:1:codex"), not inside another word.
    private static func titleNamesCodex(_ title: String?) -> Bool {
        guard let title else { return false }
        return title.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .contains("codex")
    }
}
