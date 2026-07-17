import Foundation

/// Renders continuation-shaped prompts for terminal input sources.
///
/// A shell command is not prose: feeding `git ch` after Cotabby's normal authorship preface makes a
/// base model continue the preface instead of the command. The fake transcript below establishes
/// the document form while leaving the user's exact prefix as the final bytes. Claude Code's input
/// box is natural language, so it receives a lightweight coding-assistant message frame instead.
enum TerminalCompletionPromptRenderer {
    static func prompt(
        prefixText: String,
        role: TerminalInputRole,
        shellName: String?,
        workingDirectory: String?,
        mode: SuggestionRequestMode = .continuation
    ) -> String {
        switch role {
        case .shell:
            if mode.isTerminalCommandReplacement {
                return commandReplacementPrompt(
                    instruction: prefixText,
                    shellName: shellName,
                    workingDirectory: workingDirectory
                )
            }
            let shell = shellName?.nonEmpty ?? "shell"
            let directory = compactDirectory(workingDirectory)
            let locationLine = directory.map { "Working directory: \($0)\n" } ?? ""
            return """
            Transcript of a \(shell) session on macOS.
            \(locationLine)$ cd ~/projects
            $ ls -la
            $ git status
            $ \(prefixText)
            """
        case .claudeCodeTUI:
            return """
            A developer is typing a request to an AI coding assistant. Continue the message naturally.

            \(prefixText)
            """
        }
    }

    /// Base models learn the translation shape from examples instead of an instruction-heavy chat
    /// preamble. The user's exact sentence is last so generation begins immediately after `Command:`.
    private static func commandReplacementPrompt(
        instruction: String,
        shellName: String?,
        workingDirectory: String?
    ) -> String {
        let shell = shellName?.nonEmpty ?? "shell"
        let directory = compactDirectory(workingDirectory).map { "Working directory: \($0)\n" } ?? ""
        return """
        Plain-English requests translated into one literal \(shell) command on macOS.
        \(directory)Instruction: list all files including hidden files
        Command: ls -la
        Instruction: create a folder named reports
        Command: mkdir -- reports
        Instruction: delete folder named old-build
        Command: rm -rf -- old-build
        Instruction: \(instruction)
        Command:
        """
    }

    private static func compactDirectory(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let components = URL(fileURLWithPath: raw).pathComponents.suffix(3)
        return components.joined(separator: "/").nonEmpty
    }
}

private nonisolated extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
