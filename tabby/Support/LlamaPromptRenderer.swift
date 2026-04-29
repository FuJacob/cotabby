import Foundation

/// File overview:
/// Renders the single prompt string consumed by the local llama runtime.
///
/// Why this file exists:
/// llama.cpp does not give us a separate "instructions" channel the way Foundation Models does.
/// That means all base behavior, user preferences, and request context must be composed into one
/// prompt string. Keeping that composition isolated here prevents prompt policy from leaking into
/// `SuggestionRequestFactory` or the runtime lifecycle layer.
enum LlamaPromptRenderer {
    /// Renders Tabby's local-model prompt.
    ///
    /// Tabby now always uses the instruction-rendered path. That makes custom user guidance the
    /// default behavior and avoids keeping a second "fast" prompt contract that can drift from the
    /// real product experience.
    static func prompt(
        prefixText: String,
        applicationName: String,
        completionLengthInstruction: String,
        customAIInstructions: String?,
        visualContextSummary: String? = nil
    ) -> String {
        var sections = [
            "You are Tabby's inline autocomplete engine for a macOS text field.",
            "",
            "Task:",
            "- Continue the user's existing text exactly at the caret position.",
            "- This is autocomplete, not chat. Do not answer the user or start a conversation.",
            "- Return exactly one continuation fragment.",
            "- Never repeat, restate, or quote the text before the caret.",
            "- \(completionLengthInstruction)",
            "- Match the surrounding language, tone, casing, punctuation, and formatting.",
            "",
            "Output contract:",
            "- Plain text only.",
            "- No labels, bullets, markdown, quotes, or explanation.",
            "- Start immediately with the continuation text.",
        ]

        let customInstructionLines = CustomAIInstructionFormatter.promptSectionLines(from: customAIInstructions)
        if !customInstructionLines.isEmpty {
            sections.append("")
            sections.append(contentsOf: customInstructionLines)
        }

        sections.append("")
        sections.append("Context:")
        sections.append("App: \(applicationName)")

        if let summary = visualContextSummary, !summary.isEmpty {
            sections.append("Screen content:")
            sections.append(summary)
        }

        sections.append("Text before caret:")
        sections.append(prefixText)

        return sections.joined(separator: "\n")
    }
}
