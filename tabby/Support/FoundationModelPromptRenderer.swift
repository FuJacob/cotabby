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
        var lines = [
            "You are Tabby's inline autocomplete engine for a macOS text field.",
            "Complete the user's existing text at the current caret position.",
            "This is not a chatbot.",
            "Do not answer the user as an assistant or begin a conversation.",
            "Return exactly one continuation fragment.",
            request.completionLengthInstruction,
            "Do not repeat or quote the existing text.",
            "Match the existing tone, language, casing, and punctuation.",
            "Use clipboard context only when it directly helps the inline continuation.",
            "Use plain text only with no labels, bullets, markdown, or explanation."
        ]

        var profileSections: [String] = []
        if let name = request.userName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profileSections.append("The user's name is \(name).")
        }
        if let tags = request.userTags, !tags.isEmpty {
            let tagsString = tags.joined(separator: ", ")
            profileSections.append("Things the user types often include: \(tagsString).")
        }

        if !profileSections.isEmpty {
            lines.append("User Profile Context:")
            lines.append(contentsOf: profileSections)
            lines.append("Use this context only when it fits naturally into the continuation.")
        }

        return lines.joined(separator: "\n")
    }

    /// The request prompt stays short and concrete.
    /// Foundation Models tends to behave more reliably when the prompt describes the immediate task
    /// and the stable rules live in session instructions instead of being mixed together.
    static func prompt(for request: SuggestionRequest) -> String {
        let prefixText = request.prefixText

        if prefixText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // This should be rare because upstream generation is already gated on meaningful text.
            // Returning a small fallback prompt is safer than crashing or sending an empty string.
            return "Continue the text at the caret using a short inline completion."
        }

        var sections = [
            "Screen context:",
            "App: \(request.context.applicationName)"
        ]

        if let summary = request.visualContextSummary,
           !summary.isEmpty {
            sections.append("Screen content:")
            sections.append(summary)
        }

        if let clipboardContext = request.clipboardContext,
           !clipboardContext.isEmpty {
            sections.append("")
            sections.append("User's clipboard:")
            sections.append(clipboardContext)
        }

        sections.append(contentsOf: [
            "",
            "Text before the caret:",
            prefixText,
            "",
            "Write only the next continuation fragment."
        ])

        return sections.joined(separator: "\n")
    }

    /// Diagnostics need to show both payloads Apple receives: the high-priority instructions and
    /// the shorter request prompt. Keeping this renderer-owned prevents the menu/debug preview from
    /// accidentally showing the llama prompt while Apple Intelligence is the selected engine.
    static func promptPreview(for request: SuggestionRequest) -> String {
        [
            "Instructions:",
            sessionInstructions(for: request),
            "",
            "Prompt:",
            prompt(for: request)
        ].joined(separator: "\n")
    }
}
