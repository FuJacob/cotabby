import Foundation

/// File overview:
/// Renders the prompt for the experimental base-model completion pipeline (Open Source engine with
/// `useBaseCompletionPipeline` enabled).
///
/// Why this exists separately from `LlamaPromptRenderer`:
/// `LlamaPromptRenderer` wraps the user's text in an instruction blob ("Task: ... do not answer the
/// user ...") for instruction-tuned models. A *base* model has no instruction-following channel and
/// will happily continue a bare "Task:" line as if it were the document, so that prompt shape leaks
/// scaffolding into the ghost text. This renderer instead treats the model as a pure text continuer:
///
/// - No task preamble and no standalone `Label:` lines.
/// - Custom instructions work by *conditioning*, not obedience: persona, voice, and language are
///   folded into a short framing sentence that makes the desired continuation the most likely one.
/// - Supporting context (notes/screen/clipboard) is included as compact prose ahead of the prefix.
/// - The single invariant that locates the caret is that `prefixText` is the LAST thing in the
///   prompt, with trailing whitespace trimmed so generation begins at a clean word boundary.
enum BaseCompletionPromptRenderer {
    static func prompt(
        prefixText: String,
        applicationName: String,
        userName: String?,
        customRules: [String] = [],
        extendedContext: String? = nil,
        languageInstruction: String? = nil,
        clipboardContext: String? = nil,
        visualContextSummary: String? = nil
    ) -> String {
        var preface: [String] = []

        // Persona/voice/language framing, phrased as a description of the document rather than a
        // command, because a base model conditions on description but ignores instructions. Emitted
        // only when the user supplied something, so a bare field stays pure continuation (the
        // strongest base-model setup). `applicationName` is intentionally not stated as a label here;
        // app/window metadata biases a base model toward code/numbers over prose.
        if let framing = authorFraming(
            userName: userName,
            customRules: customRules,
            languageInstruction: languageInstruction
        ) {
            preface.append(framing)
        }

        // Free-form reference notes (glossary/terminology) ahead of the prefix so the user's terms
        // become likelier continuations through in-context conditioning.
        if let extendedContext, !extendedContext.isEmpty {
            preface.append("Notes the writer keeps in mind: \(extendedContext)")
        }
        if let visualContextSummary, !visualContextSummary.isEmpty {
            preface.append("Nearby on screen: \(visualContextSummary)")
        }
        if let clipboardContext, !clipboardContext.isEmpty {
            preface.append("On the clipboard: \(clipboardContext)")
        }

        // Trailing whitespace is trimmed so the model continues from a clean word boundary instead of
        // being asked to emit a leading-space token (which base models do poorly). A prefix ending
        // mid-word keeps its final partial word, so mid-word continuation still works. Output spacing
        // is reconciled downstream by `SuggestionTextNormalizer`.
        let trimmedPrefix = Self.trimmingTrailingWhitespace(prefixText)

        guard !preface.isEmpty else {
            // No context to condition on: hand the model the bare text and let it continue.
            return trimmedPrefix
        }

        // A blank line separates the conditioning preface from the live text without a label the
        // model could copy. The prefix remains the final bytes of the prompt.
        return preface.joined(separator: "\n") + "\n\n" + trimmedPrefix
    }

    /// Builds the conditioning sentence from persona/style/language, or nil when none were supplied.
    private static func authorFraming(
        userName: String?,
        customRules: [String],
        languageInstruction: String?
    ) -> String? {
        let name = (userName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = customRules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let language = (languageInstruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty || !rules.isEmpty || !language.isEmpty else {
            return nil
        }

        var sentence = "The following is text"
        if !name.isEmpty {
            sentence += " written by \(name)"
        }
        if !rules.isEmpty {
            sentence += " in a \(rules.joined(separator: ", ")) style"
        }
        sentence += "."
        if !language.isEmpty {
            // `languageInstruction` is already a soft directive sentence; append it verbatim.
            sentence += " \(language)"
        }
        return sentence
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
