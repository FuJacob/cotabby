import Foundation

/// Prompt renderer for Compose Mode.
///
/// Compose has a different contract from inline autocomplete: it should return the exact text to
/// type at the caret, preserving paragraphs when useful, and it must not explain itself like chat.
enum ComposePromptRenderer {
    static func prompt(for request: ComposeRequest) -> String {
        var sections: [String] = []

        sections.append(
            """
            Task:
            - Write the complete text the user wants typed at the caret.
            - This is Compose Mode, not autocomplete and not chat.
            - Return only the final typeable draft.
            - Do not include labels, explanations, markdown fences, or quoted prompt text.
            - Do not repeat text already typed in the focused field unless repetition is necessary.
            - If the context is insufficient, write a concise useful draft based on the typed prefix.
            """
        )

        if let userName = request.userName?.trimmingCharacters(in: .whitespacesAndNewlines), !userName.isEmpty {
            sections.append("User name:\n\(userName)")
        }

        if let userTags = request.userTags, !userTags.isEmpty {
            sections.append("User profile tags:\n\(userTags.joined(separator: ", "))")
        }

        sections.append("App:\n\(request.applicationName)")
        sections.append("Text already typed in the focused field:\n\(emptyPlaceholder(for: request.typedPrefix))")

        if !request.trailingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Text after the caret:\n\(request.trailingText)")
        }

        if let clipboardContext = request.clipboardContext, !clipboardContext.isEmpty {
            sections.append("Clipboard context:\n\(clipboardContext)")
        }

        if let visualContextSummary = request.visualContextSummary, !visualContextSummary.isEmpty {
            sections.append("Visual context summary:\n\(visualContextSummary)")
        }

        sections.append("Relevant surrounding context:\n\(emptyPlaceholder(for: request.surroundingContext))")
        sections.append("Final instruction:\nWrite the full draft now.")

        return sections.joined(separator: "\n\n")
    }

    private static func emptyPlaceholder(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : text
    }
}
