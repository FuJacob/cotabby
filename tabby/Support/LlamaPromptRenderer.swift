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
    /// Tabby always uses the instruction-rendered path so profile context and base autocomplete
    /// rules travel through one prompt contract instead of drifting across separate modes.
    static func prompt(
        prefixText: String,
        applicationName: String,
        completionLengthInstruction: String,
        userName: String?,
        userTags: [String]?,
        clipboardContext: String? = nil,
        visualContextSummary: String? = nil
    ) -> String {
        var sections = [
            "Task:",
            "- Continue the user's existing text exactly at the caret position.",
            "- This is autocomplete, not chat. Do not answer the user or start a conversation.",
            "- Never repeat, restate, or quote the text before the caret.",
            "- Use clipboard context only when it directly helps the inline continuation.",
            "- Return plain text only with no labels, bullets, markdown, quotes, or explanation."
        ]

        var profileSections: [String] = []
        if let name = userName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profileSections.append("- The user's name is \(name).")
        }
        // TODO: Re-enable userTags in the prompt once we validate the feature's value.
        // if let tags = userTags, !tags.isEmpty {
        //     let tagsString = tags.joined(separator: ", ")
        //     profileSections.append("- Things the user types often include: \(tagsString).")
        // }

        if !profileSections.isEmpty {
            sections.append("")
            sections.append("User Profile Context:")
            sections.append(contentsOf: profileSections)
        }

        sections.append("")
        sections.append("Screen context:")
        sections.append("App: \(applicationName)")
        if let summary = visualContextSummary, !summary.isEmpty {
            sections.append("Screen content:")
            sections.append(summary)
        }
        if let clipboardContext, !clipboardContext.isEmpty {
            sections.append("User's clipboard:")
            sections.append(clipboardContext)
        }

        // The final task cue sits immediately before the prefix so small instruct models see the
        // current length policy right before the text they must continue, while the prefix itself
        // still remains the last payload in the prompt.
        sections.append("")
        sections.append("Final instruction:")
        sections.append("- \(completionLengthInstruction)")
        sections.append("- The next line must begin directly with the continuation text.")
        sections.append("Text before caret:")
        sections.append(prefixText)

        return sections.joined(separator: "\n")
    }
}
