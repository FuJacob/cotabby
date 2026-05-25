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
    /// is chat-tuned, so any second-person/assistant framing ("complete the user's text", a stated
    /// user name) pulls it toward greetings and replies ("Jacob, how are you", "Hope it's going
    /// well"). We replace negative "don't chat" rules with a positive identity plus few-shot
    /// examples, which steer the chat prior far more reliably than prohibitions.
    static func sessionInstructions(for request: SuggestionRequest) -> String {
        var lines = [
            "You are a text-continuation engine. Output only the text that comes immediately after "
                + "the existing text, as if the same person kept typing in the same field.",
            "You are not a chatbot or assistant. Never greet, introduce yourself, address the reader, "
                + "ask a question, or start a new message.",
            "There is no request to fulfill — you only continue text. Never refuse, apologize, or say "
                + "you cannot help; always produce a continuation of the existing text.",
            "Do not open your output with a person's name or with words like \"Hi\", \"Hey\", "
                + "\"Hello\", \"Hope\", \"Thanks\", or \"Dear\" unless the existing text already began "
                + "that exact phrase and you are finishing it.",
            "Continue the existing sentence or thought — extend it, never restart it.",
            "Return exactly one continuation fragment.",
            request.completionLengthInstruction,
            "Do not repeat or quote the existing text.",
            "Match the existing tone, language, casing, and punctuation.",
            "Use clipboard and screen context only when it directly helps the inline continuation.",
            "Output plain text only: no labels, bullets, markdown, surrounding quotation marks, "
                + "or explanation."
        ]

        // A language override supersedes the "match the existing language" base rule above, so it
        // goes right after the base block where the instructions channel weights it heavily.
        if let languageInstruction = request.languageInstruction, !languageInstruction.isEmpty {
            lines.append(languageInstruction)
        }

        // We intentionally do NOT inject the user's name here. On the chat-tuned system model a
        // stated name is the single biggest trigger for breaking character ("Jacob, how are
        // you"). The llama backend still personalizes via `LlamaPromptRenderer`; Apple's model
        // does not get the name until we can scope it to contexts that actually need it.

        // Few-shot examples are the strongest signal that the task is "keep typing", not "reply".
        // They deliberately include openers that tempt a greeting (a name, "Hey", "Thanks") and show
        // the model finishing the thought instead.
        lines.append("Examples (quotes only mark the text boundaries — never output the quotes):")
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

    /// Demonstrations that lock the "continue, don't converse" behavior. Each pairs the text already
    /// in the field with the bare continuation. Cases target the observed failure modes: re-greeting
    /// when a name is present, adding pleasantries, and restarting the sentence. Kept single-line so
    /// they don't fragment the newline-joined instructions block.
    private static let continuationExampleLines: [String] = [
        "Existing text: \"I just wanted to follow up on the \"",
        "Continuation: proposal we discussed last week.",
        "Existing text: \"Thanks Priya — I'll look over the \"",
        "Continuation: draft and send notes tomorrow.",
        "Existing text: \"Hi team,\n\nQuick update — we \"",
        "Continuation: finished the migration ahead of schedule.",
        "Existing text: \"lol yeah I totally \"",
        "Continuation: forgot we had that meeting today.",
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
