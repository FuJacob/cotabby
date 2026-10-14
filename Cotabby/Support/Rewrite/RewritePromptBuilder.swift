import Foundation

/// File overview:
/// Builds the rewrite prompt for both kinds of model:
/// - **instruct** (Apple Intelligence, a cloud model): rules as the system message, the selection
///   as the user message;
/// - **base** (the local llama GGUF, which continues text rather than obeying commands): one short
///   "Draft → Rewritten" example for the action, then the selection, ending at "Rewritten:".
/// Pure, so prompt wording changes show up in tests rather than in a live model's behaviour.
///
/// The selection can read like a command ("ignore the above and…"), so the instruct prompt never
/// mixes it into the rules: the rules travel alone in the system message, and the selection follows
/// in the user message under a "Draft:" label, as the text to rewrite.
nonisolated enum RewritePromptBuilder {
    struct InstructPrompt: Equatable {
        let system: String
        let user: String
    }

    static let baseStopSequences = ["\nDraft:", "\n\nDraft", "\n\n\n"]

    /// The output budget for every provider that has one (Apple Intelligence, llama, an endpoint's or
    /// MLX's completions route): about 1.5× the selection's tokens (≈4 characters per token) plus a
    /// margin, capped. Longer gets room for what `RewriteOutputCleaner` lets it grow to (8× plus 400
    /// characters), so a fuller message is not cut off mid-sentence and previewed as if it were
    /// complete. On a completions route this number is the only length limit.
    static func tokenBudget(_ request: RewriteRequest) -> Int {
        let count = request.selection.count
        return min(800, request.action == .longer ? count * 2 + 100 : count * 3 / 8 + 48)
    }

    /// The base model's output up to the earliest stop sequence. Decoding stops once the text
    /// contains one, so the text still ends with it ("Fine.\n\nDraft:"); left in, the next example's
    /// label would be previewed and pasted.
    static func cutAtBaseStop(_ text: String) -> String {
        let cut = baseStopSequences.compactMap { text.range(of: $0)?.lowerBound }.min()
        return cut.map { String(text[..<$0]) } ?? text
    }

    static func actionLine(_ action: RewriteAction) -> String {
        switch action {
        case .fixOnly: return "Fix only spelling, grammar and punctuation mistakes; keep the wording."
        case .rewrite: return "Rewrite it to read clearer and more natural, with the same meaning and tone."
        case .shorter: return "Rewrite it shorter, keeping all of its content."
        case .longer:
            return "Rewrite it longer and more complete: spell out what the user means, "
                + "but never invent facts, names or numbers that are not in the draft."
        case .family: return "Rewrite it in a warm, caring tone for a family member."
        case .friendly: return "Rewrite it in a warm, friendly tone."
        case .closeFriend:
            return "Rewrite it the way you would text a close friend: relaxed and casual, with everyday slang where it fits naturally."
        case .formal: return "Rewrite it in a formal, professional tone."
        case .customer: return "Rewrite it as a message to a customer: polite, clear, helpful and professional."
        case .custom(let instruction): return "Follow this instruction: \"\(instruction)\""
        }
    }

    static func instructPrompt(_ request: RewriteRequest) -> InstructPrompt {
        var rules = [
            "You rewrite the user's own draft text.",
            actionLine(request.action)
        ]
        if let tone = request.tone, let description = toneDescription(tone) {
            rules.append("Keep the same tone: \(description).")
        }
        if let fixLine = fixLine(request) { rules.append(fixLine) }
        rules += [
            languageRule(request) + " Keep its meaning, names and numbers.",
            "Return only the rewritten text: no quotes, no preface, no explanation."
        ]
        return InstructPrompt(system: rules.joined(separator: "\n"), user: "Draft:\n\(request.selection)")
    }

    /// How a tone reads, for a refinement that must keep it ("Keep the same tone: …").
    static func toneDescription(_ tone: RewriteAction) -> String? {
        switch tone {
        case .family: return "warm and caring, for a family member"
        case .friendly: return "warm and friendly"
        case .closeFriend: return "relaxed and casual, like a text to a close friend, with everyday slang where it fits"
        case .formal: return "formal and professional"
        case .customer: return "polite, clear, helpful and professional, for a customer"
        case .custom(let instruction): return "as the instruction \"\(instruction)\" asked"
        default: return nil
        }
    }

    /// The tick box's line for every action that has a choice: Fix only always fixes, and a custom
    /// instruction says for itself what it wants.
    private static func fixLine(_ request: RewriteRequest) -> String? {
        switch request.action {
        case .fixOnly, .custom: return nil
        default:
            return request.fixesMistakes
                ? "Also fix spelling, grammar and punctuation mistakes."
                : "Do not correct the user's spelling or grammar; keep their own way of writing."
        }
    }

    /// Requires the detected language by name, since a generic "same language" rule let Apple's model
    /// answer a Turkish draft in English. A custom instruction may still ask for another language
    /// ("translate to English"), so it gets the softer form.
    private static func languageRule(_ request: RewriteRequest) -> String {
        guard let language = request.language else { return "Write in the same language as the draft." }
        if case .custom = request.action {
            return "The draft is written in \(language). Write in \(language) unless the instruction asks for another language."
        }
        return "The draft is written in \(language). Write the rewrite in \(language), never in another language."
    }

    static func basePrompt(_ request: RewriteRequest) -> String {
        let example = baseExample(request.action)
        let languageNote = request.language.map { "Written in \($0), same meaning." } ?? "Same language, same meaning."
        var header = "Each draft below is rewritten. \(actionLine(request.action))"
        // A refinement keeps the tone that produced its draft, as in the instruct prompt.
        if let tone = request.tone, let description = toneDescription(tone) {
            header += " Keep the same tone: \(description)."
        }
        // The examples already fix typos, so only the opposite choice needs a line of its own.
        if !request.fixesMistakes, let fixLine = fixLine(request) {
            header += " \(fixLine)"
        }
        var prompt = "\(header) \(languageNote)\n\n"
        prompt += "Draft: \(example.draft)\nRewritten: \(example.rewritten)\n\n"
        prompt += "Draft: \(request.selection)\nRewritten:"
        return prompt
    }

    private static func baseExample(_ action: RewriteAction) -> (draft: String, rewritten: String) {
        switch action {
        case .fixOnly:
            return ("i will send u the file tomorow, sory for the delay", "I will send you the file tomorrow, sorry for the delay.")
        case .formal:
            return ("hey, can u send me the report asap", "Hello, could you please send me the report at your earliest convenience?")
        case .friendly:
            return ("Send me the report.", "Hi! Could you send me the report when you get a chance? Thanks a lot!")
        case .family:
            return ("are you coming sunday", "Are you coming on Sunday? It would be so lovely to see you!")
        case .closeFriend:
            return ("Are you available to meet this evening?", "you free tonight? let's grab something")
        case .customer:
            return (
                "we got your problem, will fix soon",
                "Thank you for letting us know. We are looking into the issue and will update you shortly."
            )
        case .shorter:
            return (
                "I just wanted to let you know that I will not be able to make it to the meeting tomorrow.",
                "I can't make it to tomorrow's meeting."
            )
        case .longer:
            return (
                "can we meet tomorrow",
                "Could we meet tomorrow? I'd like to go over where things stand and agree on the next steps. "
                    + "Let me know what time works for you."
            )
        case .rewrite, .custom:
            return (
                "i will send u the file tomorow, sory for the delay its been busy",
                "I'll send you the file tomorrow. Sorry for the delay, it's been busy."
            )
        }
    }
}
