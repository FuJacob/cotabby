import Foundation

/// File overview:
/// Renders the prompt for Cotabby's base-model completion pipeline (the Open Source / llama path).
///
/// Design: a *base* model has no instruction-following channel and will happily continue a bare
/// "Task:" line as if it were the document, so an instruction-blob prompt would leak scaffolding into
/// the ghost text. This renderer treats the model as a pure text continuer: persona, style, language,
/// and supporting context are folded into a short conditioning preface (a base model conditions on
/// description, it does not obey commands), and the exact caret prefix is the LAST thing in the
/// prompt. Spaces, line breaks, and indentation remain part of the text the model continues.
///
/// Sections are character-budgeted via `PromptSectionBudget` so a large glossary, clipboard, or
/// screen capture can never crowd out the caret text: the prefix gets top priority and a guaranteed
/// minimum, and context fills the remaining budget by priority.
enum BaseCompletionPromptRenderer {
    /// Total character budget for the preface plus caret prefix. The prefix arrives already windowed
    /// by `SuggestionRequestFactory`, so this mainly caps how much optional context rides along.
    static let defaultContextBudget = 6400

    static func prompt(
        prefixText: String,
        applicationName: String,
        userName: String?,
        trailingText: String = "",
        maxSuffixCharacters: Int = 192,
        customRules: [String] = [],
        extendedContext: String? = nil,
        languageInstruction: String? = nil,
        clipboardContext: String? = nil,
        visualContextSummary: String? = nil,
        surfaceContext: SurfaceContext? = nil,
        historyExamples: [String] = [],
        usesCompactSurfaceContext: Bool = false,
        contextBudget: Int = defaultContextBudget,
        maxScreenCharacters: Int = 4000,
        screenPriority: Int = 45,
        tokenBudget: Int? = nil
    ) -> String {
        var sections: [PromptSection] = []
        // The surface description leads the preface: knowing the writing surface (email in Mail,
        // a chat in Slack, a document title) is the strongest situational cue a base model gets,
        // and the composer already omits it for the app classes where metadata would hurt. The
        // facts remain stable during ordinary typing; navigation refreshes them even when doing
        // so sacrifices KV reuse. Context freshness takes precedence over a cached prompt head.
        if let section = surfaceSection(surfaceContext, compact: usesCompactSurfaceContext) {
            sections.append(section)
        }
        if let persona = Self.personaLine(userName, prefix: prefixText) {
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
            // of being silently clipped far under the advertised cap. It still competes for the total
            // total budget below (priority 40), so an unusually long prefix can trim it, but in normal use
            // the whole blob lands.
            sections.append(Self.contextSection("notes", "Notes the writer keeps in mind: \(notes)", priority: 40, maxChars: 1300))
        }
        if let history = Self.historySection(historyExamples) {
            sections.append(history)
        }
        if let clip = Self.nonEmpty(clipboardContext) {
            sections.append(Self.contextSection("clipboard", "On the clipboard: \(clip)", priority: 35, maxChars: 400))
        }
        if let screen = Self.nonEmpty(visualContextSummary) {
            sections.append(Self.contextSection(
                "screen", "Nearby on screen: \(screen)", priority: screenPriority, maxChars: maxScreenCharacters
            ))
        }
        let followingText = String(trailingText.prefix(max(0, maxSuffixCharacters)))
        if !followingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Base models do not share a universal fill-in-the-middle token format. Describe the
            // existing ending as quoted reference material, then leave the actual caret prefix
            // last. Keep this changing field context after the stable preface to retain cache reuse.
            // The whole bounded section is optional: dropping it under pressure keeps the quote
            // delimiters intact and prevents an unfinished label from becoming completion text.
            let followingSection = "Later in the same passage:\n“\(followingText)”"
            sections.append(PromptSection(
                name: "following",
                content: followingSection,
                priority: 80,
                minChars: followingSection.count,
                maxChars: followingSection.count,
                truncation: .preserveStart,
                preservesWhitespace: true
            ))
        }
        // The caret prefix: top priority so it is never starved, kept by its END (the text nearest
        // the caret), and rendered last with no label so the model continues from where the user
        // stopped. `applicationName` is intentionally not stated; app/window metadata biases a base
        // model toward code/numbers over prose.
        sections.append(
            PromptSection(
                name: "prefix",
                content: prefixText,
                priority: 100,
                minChars: 1,
                maxChars: max(1, prefixText.count),
                truncation: .preserveEnd,
                preservesWhitespace: true
            )
        )

        let kept = allocate(sections, contextBudget: contextBudget, tokenBudget: tokenBudget)
        let prefix = kept.first { $0.name == "prefix" }?.content ?? ""
        let preface = kept.filter { $0.name != "prefix" }.map(\.content)

        guard !preface.isEmpty else {
            // No context to condition on: hand the model the bare text and let it continue.
            return prefix
        }
        // A blank line separates the conditioning preface from the live text without a label the
        // model could copy. The prefix remains the final bytes of the prompt.
        return preface.joined(separator: "\n") + "\n\n" + prefix
    }

    /// Token-aware budgeting (opt-in): when a token budget is supplied, fill sections against an
    /// estimated-token window instead of the character approximation. Defaults to the character
    /// path so shipped behavior is unchanged.
    private static func allocate(_ sections: [PromptSection], contextBudget: Int, tokenBudget: Int?) -> [PromptSection] {
        guard let tokenBudget else {
            return PromptSectionBudget.allocate(sections, totalChars: contextBudget)
        }
        return PromptSectionBudget.allocate(sections, totalTokens: tokenBudget, estimate: TokenCountEstimator.estimate)
    }

    /// Surface metadata is one optional section; its representation does not affect budgeting.
    private static func surfaceSection(_ surface: SurfaceContext?, compact: Bool) -> PromptSection? {
        guard let surface else { return nil }
        // Compact rendering remains an opt-in evaluation control.
        let lines = compact
            ? SurfaceContextComposer.baseCompletionPrefaceLines(for: surface)
            : SurfaceContextComposer.prefaceLines(for: surface)
        guard !lines.isEmpty else { return nil }
        return contextSection("surface", lines.joined(separator: " "), priority: 70, maxChars: 240)
    }

    /// The user's own earlier sentences, quoted. A base model conditions strongly on nearby text in
    /// the same voice, so a couple of real examples pull its word choice toward how this person
    /// writes. Sits after the stable preface and before the per-keystroke clipboard and screen
    /// sections: the examples change only every few words (`TypingHistoryQuery.stableText`), so
    /// placing them earlier keeps more of the prompt's head reusable from the KV cache.
    ///
    /// All or nothing, like the "following" section: a budget-trimmed history section could end
    /// on an unclosed quote, and the model would then read the live caret text as part of that
    /// quote. Examples are dropped whole until the section fits its cap.
    private static func historySection(_ examples: [String]) -> PromptSection? {
        let heading = "Earlier writing by the same author:"
        var content = heading
        for example in examples {
            let trimmed = example.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let line = "\n“\(trimmed)”"
            guard content.count + line.count <= historyMaxCharacters else { continue }
            content += line
        }
        guard content.count > heading.count else { return nil }
        return PromptSection(
            name: "history",
            content: content,
            priority: 38,
            minChars: content.count,
            maxChars: content.count,
            truncation: .preserveStart
        )
    }

    private static let historyMaxCharacters = 760

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
}
