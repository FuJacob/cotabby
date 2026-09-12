import Foundation

/// File overview:
/// Renders the prompt for Cotabby's base-model completion pipeline (the Open Source / llama path).
///
/// Design: a *base* model has no instruction-following channel and will happily continue a bare
/// "Task:" line as if it were the document, so an instruction-blob prompt would leak scaffolding into
/// the ghost text. This renderer treats the model as a pure text continuer: persona, style, language,
/// and supporting context are folded into a short conditioning preface (a base model conditions on
/// description, it does not obey commands), and the caret prefix is the LAST thing in the prompt with
/// trailing whitespace trimmed so generation begins at a clean word boundary. The trim applies to
/// prompts anchored at a word boundary (`WordBoundaryAnchorPolicy`) too, even though the model then
/// sometimes continues the previous word ("…yesterday. I" → "I've") instead of starting the one the
/// user began: a prompt that ends in a space is worse, measured live with the shipped model it
/// answered "1234567890" and stray HTML tags to most requests.
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
        surfaceContext: SurfaceContext? = nil,
        contextBudget: Int = defaultContextBudget,
        tokenBudget: Int? = nil
    ) -> String {
        let trimmedPrefix = Self.trimmingTrailingWhitespace(prefixText)

        var sections: [PromptSection] = []
        // The surface description leads the preface: knowing the writing surface (email in Mail,
        // a chat in Slack, a document title) is the strongest situational cue a base model gets,
        // and the composer already omits it for the app classes where metadata would hurt. The
        // value is frozen per field session upstream, so these bytes stay stable across keystrokes
        // and the llama KV prefix reuse keeps amortizing them.
        if let surface = surfaceContext {
            let lines = SurfaceContextComposer.prefaceLines(for: surface)
            if !lines.isEmpty {
                sections.append(
                    Self.contextSection("surface", lines.joined(separator: " "), priority: 70, maxChars: 240)
                )
            }
        }
        if let persona = Self.personaLine(userName, prefix: trimmedPrefix) {
            sections.append(Self.contextSection("persona", persona, priority: 60, maxChars: 200))
        }
        if let style = Self.styleLine(customRules) {
            sections.append(Self.contextSection("style", style, priority: 55, maxChars: 300))
        }
        if let language = Self.nonEmpty(languageInstruction) {
            sections.append(Self.contextSection("language", language, priority: 50, maxChars: 300))
        }
        if let notes = Self.nonEmpty(extendedContext) {
            // `maxChars` must stay at or above `SuggestionSettingsModel.maximumExtendedContextCharacters`
            // plus this label (~32 chars) so the full user-entered Extended Context survives here instead
            // of being silently clipped far under the advertised cap. It still competes for the 2400-char
            // total budget below (priority 40), so an unusually long prefix can trim it, but in normal use
            // the whole blob lands.
            sections.append(Self.contextSection("notes", "Notes the writer keeps in mind: \(notes)", priority: 40, maxChars: 1300))
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
        // The budget trims every section at both ends; a line break the caret follows belongs to
        // the prefix (see `trimmingTrailingWhitespace`), so it goes back on.
        let prefix = kept.first { $0.name == "prefix" }.map { $0.content + Self.trailingWhitespace(of: trimmedPrefix) }
            ?? trimmedPrefix
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

    /// "Written by <name>." when the caret follows a valediction (see `SignOffCue`), nil otherwise.
    ///
    /// The name is deliberately absent from every other prompt. A base model given a name in its
    /// preface reaches for it whenever the caret text is thin, and the live logs (2026-09-10,
    /// 31 of 2844 generations) showed it introducing the writer at message openings, addressing
    /// them as the recipient, and copying "written by" into the ghost text. At a sign-off the name
    /// is the one token wanted, and the closing line anchors the model so nothing else leaks.
    private static func personaLine(_ userName: String?, prefix: String) -> String? {
        guard let name = Self.nonEmpty(userName), SignOffCue.precedesSignature(prefix) else { return nil }
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

    /// The whitespace `text` ends with: after `trimmingTrailingWhitespace`, only the line breaks the
    /// caret follows (with any spaces between them).
    private static func trailingWhitespace(of text: String) -> String {
        String(text.reversed().prefix { $0.isWhitespace }.reversed())
    }

    /// Drops trailing spaces and tabs so the base-model prompt ends at a word boundary (a tokenizer
    /// carries a word's space on the word). A trailing line break stays: it is a token of its own,
    /// and it is how the model learns that the caret opens a new line or paragraph. An anchored
    /// request for that line's first word then requires the word without the break (see
    /// `WordBoundaryAnchorPolicy.requiredCompletionPrefix`).
    static func trimmingTrailingWhitespace(_ text: String) -> String {
        var view = Substring(text)
        while let last = view.last, last.isWhitespace, !last.isNewline {
            view = view.dropLast()
        }
        return String(view)
    }
}
