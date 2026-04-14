import Foundation

/// File overview:
/// Adapts Tabby's shared suggestion request into the prompting style that works best with Apple's
/// Foundation Models framework.
///
/// Why this file exists:
/// llama.cpp and Apple's on-device model accept the same high-level task, but they respond best
/// to different prompt shapes. The local llama runtime consumes one prompt string directly, while
/// Foundation Models gives us a first-class instructions channel. Keeping that translation here
/// prevents Apple-specific prompt policy from leaking back into `SuggestionCoordinator` or the
/// shared request factory.
enum FoundationModelPromptRenderer {
    /// Session instructions define the model's role and output contract.
    /// Apple documents that instructions have higher priority than the prompt itself, which makes
    /// them the right place to say "this is autocomplete, not chat."
    static func sessionInstructions(for request: SuggestionRequest) -> String {
        [
            "You are an inline autocomplete engine for one text field.",
            "Complete the user's existing text at the current caret position.",
            "Do not answer the user as an assistant or begin a conversation.",
            "Do not greet the user, ask follow-up questions, or turn the text into chat unless that is the direct continuation of the existing text.",
            "Return exactly one continuation fragment.",
            request.customAIInstructions,
            "Do not repeat or quote the existing text.",
            "Match the existing tone, casing, and punctuation.",
            "Use plain text only with no labels, bullets, markdown, or explanation."
        ]
        .joined(separator: "\n")
    }

    /// The request prompt stays short and concrete.
    /// Foundation Models tends to behave more reliably when the prompt describes the immediate task
    /// and the stable rules live in session instructions instead of being mixed together.
    static func prompt(for request: SuggestionRequest) -> String {
        let prefixText = request.prefixText.trimmingCharacters(in: .whitespacesAndNewlines)

        if prefixText.isEmpty {
            // This should be rare because upstream generation is already gated on meaningful text.
            // Returning a small fallback prompt is safer than crashing or sending an empty string.
            return "Continue the text at the caret using a short inline completion."
        }

        return [
            "Text before the caret:",
            prefixText,
            "",
            "Write only the next continuation fragment."
        ]
        .joined(separator: "\n")
    }
}
