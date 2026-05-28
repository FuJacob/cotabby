import Foundation

/// File overview:
/// Adapts Cotabby's shared suggestion request into the prompting style that works best with Apple's
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
    ///
    /// The framing is deliberately *text continuation*, not *assist the user*. Apple's system model
    /// is chat-tuned, so any second-person/assistant framing pulls it toward greetings and
    /// replies. Apple's WWDC25 prompt-design guidance is to use a positive identity plus a small
    /// number of demonstrations rather than a long list of prohibitions, so the rules here stay
    /// short, positive, and concrete; the two few-shot examples below carry the rest of the
    /// anti-drift signal.
    static func sessionInstructions(for request: SuggestionRequest) -> String {
        var lines = [
            "You complete partially-typed text. The user is the author; you produce the next "
                + "few words they would type, in their voice.",
            "Output the continuation only: no greeting, no sign-off, no quotes, no markdown, "
                + "no labels, no explanation.",
            // Anti-echo guard. Without an explicit rule the chat-tuned model sometimes emits the
            // existing text again instead of continuing — most reliably on mid-line comment and
            // mid-sentence prose prefixes — which the normalizer then strips, leaving the user
            // with no suggestion at all. The rule is paired with positive framing so it does not
            // violate the WWDC25 "positive identity over prohibitions" guidance that motivates
            // this rewrite.
            "Continue from the position immediately after the existing text. Do not repeat or "
                + "quote the existing text.",
            "Match the existing language, register, casing, and punctuation. Continue the "
                + "current sentence or thought rather than restarting it.",
            "Use clipboard or screen context only when it directly helps the next words."
        ]

        // The declared-language hint refines the "match the existing language" rule above. It sits
        // right after the base block so the instructions channel weights it heavily.
        if let languageInstruction = request.languageInstruction, !languageInstruction.isEmpty {
            lines.append(languageInstruction)
        }

        // We intentionally do NOT inject the user's name here. On the chat-tuned system model a
        // stated name is the single biggest trigger for breaking character ("Jacob, how are
        // you"). The llama backend still personalizes via `LlamaPromptRenderer`; Apple's model
        // does not get the name until we can scope it to contexts that actually need it.

        // Two few-shot examples (down from five) carry the heavy anti-drift signal. The first
        // proves "finish a salutation-adjacent sentence without restarting"; the second proves
        // "code prefixes produce code, not prose." Both are also short, which matters because
        // instructions land in Apple's 4096-token shared context and earn their tokens.
        lines.append("Examples (quotes only mark the boundaries; never output the quotes):")
        lines.append(contentsOf: Self.continuationExampleLines)

        // Style rules live in the high-priority instructions channel like the base rules, but are
        // appended last with an explicit subordination line so they cannot override the output
        // contract above.
        let trimmedRules = request.customRules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmedRules.isEmpty {
            lines.append("Your style preferences:")
            lines.append(contentsOf: trimmedRules.map { "- \($0)" })
            lines.append("Apply these only when they fit the continuation naturally; never break the rules above.")
        }

        return lines.joined(separator: "\n")
    }

    /// The minimal demonstration set that locks in "continue, do not converse." One prose pair
    /// covers the salutation-restart failure mode the chat-tuned model is most prone to; one code
    /// pair establishes that code prefixes get code continuations, not English prose.
    private static let continuationExampleLines: [String] = [
        "Existing text: \"I just wanted to follow up on the \"",
        "Continuation: proposal we discussed last week.",
        "Existing text: \"def total(items): return \"",
        "Continuation: sum(item.price for item in items)"
    ]

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
            "User is on \(request.context.applicationName)."
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
