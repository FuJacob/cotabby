import Foundation

/// File overview:
/// Centralizes the last-mile cleanup that turns raw model output into inline ghost text.
/// Both llama.cpp and Apple's Foundation Models backend feed through this helper so prompt
/// formatting quirks stay in one place instead of drifting across runtime implementations.
///
/// This type is intentionally pure. Given the same request and raw output, it always returns the
/// same normalized suggestion. That makes it safe to share across backends and easy to test later.
enum SuggestionTextNormalizer {
    static func normalize(_ rawSuggestion: String, for request: SuggestionRequest) -> String {
        var normalized = rawSuggestion.replacingOccurrences(of: "\r", with: "")

        // Some runtimes echo the prompt or include chat-template control markers in the response.
        // Removing them here keeps the UI layer independent from backend-specific formatting.
        normalized = normalized.replacingOccurrences(of: "<|im_end|>", with: "")
        normalized = normalized.replacingOccurrences(of: "<|im_start|>", with: "")

        if !request.prompt.isEmpty, normalized.hasPrefix(request.prompt) {
            normalized.removeFirst(request.prompt.count)
        }

        // Apple Intelligence uses a separate instructions channel and a short task prompt, so the
        // model may echo only the visible prefix text instead of the full prompt payload.
        if !request.prefixText.isEmpty, normalized.hasPrefix(request.prefixText) {
            normalized.removeFirst(request.prefixText.count)
        }

        // Inline autocomplete should only surface the immediate continuation, not a paragraph.
        if
            let firstLine = normalized.split(
                separator: "\n",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first
        {
            normalized = String(firstLine)
        }

        normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))

        // If the model starts by repeating text that already exists after the caret, we treat the
        // suggestion as unusable. Showing only the remainder often produces confusing mid-word
        // ghosts, so the coordinator should regenerate instead.
        if !request.context.trailingText.isEmpty,
            normalized.hasPrefix(request.context.trailingText)
        {
            return ""
        }

        return normalized.trimmingCharacters(in: .newlines)
    }
}
