import Foundation

/// File overview:
/// Renders the prompt for Cotabby's base-model completion pipeline (the Open Source / llama path).
///
/// Design: a *base* model has no instruction-following channel and will happily continue a bare
/// "Task:" line as if it were the document, so an instruction-blob prompt would leak scaffolding into
/// the ghost text. This renderer treats the model as a pure text continuer: persona, style, language,
/// and supporting context are folded into a short conditioning preface (a base model conditions on
/// description, it does not obey commands), and the caret prefix is the LAST thing in the prompt with
/// trailing whitespace trimmed so generation begins at a clean word boundary.
///
/// Sections are character-budgeted via `PromptSectionBudget` so a large glossary, clipboard, or
/// screen capture can never crowd out the caret text: the prefix gets top priority and a guaranteed
/// minimum, and context fills the remaining budget by priority.
enum BaseCompletionPromptRenderer {
    /// Total character budget for the preface plus caret prefix. The prefix arrives already windowed
    /// by `SuggestionRequestFactory`, so this mainly caps how much optional context rides along.
    static let defaultContextBudget = 2400

    static func prompt(
        prefixText: String,
        applicationName: String,
        userName: String?,
        customRules: [String] = [],
        extendedContext: String? = nil,
        languageInstruction: String? = nil,
        clipboardContext: String? = nil,
        visualContextSummary: String? = nil,
        contextBudget: Int = defaultContextBudget,
        tokenBudget: Int? = nil
    ) -> String {
        let trimmedPrefix = Self.trimmingTrailingWhitespace(prefixText)

        var sections: [PromptSection] = []
        if let persona = Self.personaLine(userName) {
            sections.append(Self.contextSection("persona", persona, priority: 60, maxChars: 200))
        }
        if let style = Self.styleLine(customRules) {
            sections.append(Self.contextSection("style", style, priority: 55, maxChars: 300))
        }
        if let language = Self.nonEmpty(languageInstruction) {
            sections.append(Self.contextSection("language", language, priority: 50, maxChars: 300))
        }
        if let notes = Self.nonEmpty(extendedContext) {
            sections.append(Self.contextSection("notes", "Notes the writer keeps in mind: \(notes)", priority: 40, maxChars: 600))
        }
        if let clip = Self.nonEmpty(clipboardContext) {
            sections.append(Self.contextSection("clipboard", "On the clipboard: \(clip)", priority: 35, maxChars: 400))
        }
        if let screen = Self.nonEmpty(visualContextSummary) {
            sections.append(Self.contextSection("screen", "Nearby on screen: \(screen)", priority: 30, maxChars: 500))
        }
        // The caret prefix: top priority so it is never starved, kept by its END (the text nearest
        // the caret), and rendered last with no label so the model continues from where the user
        // stopped. `applicationName` is intentionally not stated; app/window metadata biases a base
        // model toward code/numbers over prose.
        sections.append(
            PromptSection(
                name: "prefix",
                content: trimmedPrefix,
                priority: 100,
                minChars: 1,
                maxChars: max(1, trimmedPrefix.count),
                truncation: .preserveEnd
            )
        )

        // Token-aware budgeting (opt-in): when a token budget is supplied, fill sections against an
        // estimated-token window instead of the character approximation. Defaults to the character
        // path so shipped behavior is unchanged.
        let kept: [PromptSection]
        if let tokenBudget {
            kept = PromptSectionBudget.allocate(
                sections,
                totalTokens: tokenBudget,
                estimate: TokenCountEstimator.estimate
            )
        } else {
            kept = PromptSectionBudget.allocate(sections, totalChars: contextBudget)
        }
        let prefix = kept.first { $0.name == "prefix" }?.content ?? trimmedPrefix
        let preface = kept.filter { $0.name != "prefix" }.map(\.content)

        guard !preface.isEmpty else {
            // No context to condition on: hand the model the bare text and let it continue.
            return prefix
        }
        // A blank line separates the conditioning preface from the live text without a label the
        // model could copy. The prefix remains the final bytes of the prompt.
        return preface.joined(separator: "\n") + "\n\n" + prefix
    }

    private static func contextSection(
        _ name: String,
        _ content: String,
        priority: Int,
        maxChars: Int
    ) -> PromptSection {
        PromptSection(name: name, content: content, priority: priority, minChars: 0, maxChars: maxChars, truncation: .preserveStart)
    }

    /// "Written by <name>." or nil. Conditions the voice via authorship framing.
    private static func personaLine(_ userName: String?) -> String? {
        guard let name = Self.nonEmpty(userName) else { return nil }
        return "Written by \(name)."
    }

    /// "Writing style: <rules>." or nil. Rendered as its own line rather than jammed into an
    /// "in a <rules> style" clause, so multi-word and sentence-shaped rules read correctly and
    /// condition cleanly (the old clause produced broken prose like "in a Use British spelling style").
    private static func styleLine(_ customRules: [String]) -> String? {
        let rules = customRules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rules.isEmpty else { return nil }
        return "Writing style: \(rules.joined(separator: ", "))."
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Drops trailing spaces, tabs, and newlines so the base-model prompt ends at a word boundary.
    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var view = Substring(text)
        while let last = view.last, last.isWhitespace {
            view = view.dropLast()
        }
        return String(view)
    }
}
