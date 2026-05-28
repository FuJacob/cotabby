import Foundation

/// File overview:
/// Renders the prompt sent to the local llama runtime when Cotabby is in correction mode —
/// the user's last word looks misspelled and we're asking the model for a context-aware fix.
///
/// Why a separate file from `LlamaPromptRenderer`:
/// the correction prompt has a fundamentally different output contract (one corrected word, no
/// continuation) and mixing it into the general autocomplete renderer would force a mode-flag
/// branch through every section. Keeping them apart preserves the simple "one prompt = one
/// shape" rule for both.
enum CorrectionPromptRenderer {
    struct Metadata {
        let applicationName: String
        let userName: String?
        let languageInstruction: String?
    }

    static func prompt(
        precedingTextBeforeTypo: String,
        typoWord: String,
        nativeCorrectionsHint: [String],
        metadata: Metadata
    ) -> String {
        let applicationName = metadata.applicationName
        let userName = metadata.userName
        let languageInstruction = metadata.languageInstruction
        var sections = [
            "Task:",
            "- The user's most recent word looks misspelled. Output the corrected word only.",
            "- Reply with one word. No explanation, no quotes, no punctuation surrounding it, no markdown.",
            "- Match the user's intended capitalization when it's obvious from the typo.",
            "- Use the surrounding context to pick the correction that fits.",
            "- If you can't confidently improve the word, repeat it verbatim and we'll drop the suggestion."
        ]

        if let name = userName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("")
            sections.append("The user's name is \(name).")
        }

        if let languageInstruction, !languageInstruction.isEmpty {
            sections.append("")
            sections.append(languageInstruction)
        }

        sections.append("")
        sections.append("Screen context:")
        sections.append("User is on \(applicationName).")

        sections.append("")
        sections.append("Text written before the typo (may be empty):")
        sections.append(precedingTextBeforeTypo)

        // Top three NSSpellChecker guesses go in as a hint, not a constraint. The model is free to
        // ignore them when surrounding context points elsewhere — e.g. spellchecker says "myth"
        // for "myy" but the sentence makes "my" the obvious fix.
        let trimmedHints = nativeCorrectionsHint
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
        if !trimmedHints.isEmpty {
            sections.append("")
            sections.append("Spellchecker hints (use only when they fit the context): \(trimmedHints.joined(separator: ", "))")
        }

        sections.append("")
        sections.append("Typo: \(typoWord)")
        sections.append("Corrected word:")
        return sections.joined(separator: "\n")
    }
}
