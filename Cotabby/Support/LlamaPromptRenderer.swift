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
    /// Renders Cotabby's local-model prompt.
    ///
    /// Cotabby always uses the instruction-rendered path so profile context and base autocomplete
    /// rules travel through one prompt contract instead of drifting across separate modes.
    static func prompt(
        prefixText: String,
        applicationName: String,
        completionLengthInstruction: String,
        userName: String?,
        customRules: [String] = [],
        languageInstruction: String? = nil,
        clipboardContext: String? = nil,
        visualContextSummary: String? = nil
    ) -> String {
        var sections = [
            "Task:",
            "- Continue the user's existing text exactly at the caret position.",
            "- This is autocomplete, not chat. Do not answer the user or start a conversation.",
            "- Never repeat, restate, or quote the text before the caret.",
            "- Use clipboard context only when it directly helps the inline continuation.",
            "- Return plain text only with no thinking, labels, bullets, markdown, quotes, or explanation."
        ]

        var profileSections: [String] = []
        if let name = userName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profileSections.append("- The user's name is \(name).")
        }
        if !profileSections.isEmpty {
            sections.append("")
            sections.append("User Profile Context:")
            sections.append(contentsOf: profileSections)
        }

        // User style rules render after the base task rules and profile, with an explicit
        // subordination line so a user "rule" can never override the autocomplete/output contract
        // above (prompt-injection guard).
        let trimmedRules = customRules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmedRules.isEmpty {
            sections.append("")
            sections.append("Your style preferences:")
            sections.append(contentsOf: trimmedRules.map { "- \($0)" })
            sections.append("Apply these only when they fit the continuation naturally; never break the rules above.")
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
        // Language directive sits in the late, high-attention block right before the prefix so
        // small instruct models don't drift back to the input's language mid-completion.
        if let languageInstruction, !languageInstruction.isEmpty {
            sections.append("- \(languageInstruction)")
        }
        sections.append("- \(completionLengthInstruction)")
        sections.append("- The next line must begin directly with the continuation text.")
        sections.append("Text before caret:")
        sections.append(prefixText)

        return sections.joined(separator: "\n")
    }
}
