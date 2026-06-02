import Foundation

/// File overview:
/// Pure character-budget allocator for the base-model prompt.
///
/// Why this exists:
/// Once the base prompt carries optional context (a glossary, clipboard, screen OCR, the text after
/// the caret), an unbounded concatenation can crowd out the one thing that actually matters, the
/// caret text the model must continue, or blow the model's context window. This allocator lets each
/// section declare a priority and a min/max character budget; `allocate` fills sections
/// highest-priority-first within a total budget and truncates each to fit, so the caret text (given
/// the top priority and a guaranteed minimum) is never starved by a noisy screen capture.
///
/// Character-based, not tokenizer-based, on purpose: it keeps this layer pure and deterministic for
/// tests and free of a runtime dependency. It is a safe approximation (roughly 4 chars per token)
/// and can be swapped for a real token count later without changing the section contract.
struct PromptSection: Equatable, Sendable {
    /// Which end of the content to keep when it must be shortened. `beforeCursor` keeps its END
    /// (the text nearest the caret); `afterCursor` keeps its START (the text nearest the caret).
    enum Truncation: Equatable, Sendable {
        case preserveStart
        case preserveEnd
    }

    let name: String
    var content: String
    /// Higher priority is filled (and kept) first when the budget is tight.
    let priority: Int
    /// If the remaining budget can't fit at least this many characters, the section is dropped
    /// rather than included as a uselessly-tiny fragment. Use 0 to mean "include whatever fits".
    let minChars: Int
    let maxChars: Int
    let truncation: Truncation
}

enum PromptSectionBudget {
    /// Fills sections by priority (descending, ties broken by original order for determinism) within
    /// `totalChars`. Each section is capped at `min(maxChars, contentLength, remainingBudget)`, gets
    /// dropped if that is below its `minChars`, and gets dropped if it trims to empty. Surviving
    /// sections are returned in their ORIGINAL order so the caller keeps control of render order
    /// independently of fill priority.
    static func allocate(_ sections: [PromptSection], totalChars: Int) -> [PromptSection] {
        var remaining = max(0, totalChars)

        let fillOrder = sections.enumerated().sorted { lhs, rhs in
            lhs.element.priority == rhs.element.priority
                ? lhs.offset < rhs.offset
                : lhs.element.priority > rhs.element.priority
        }

        var kept: [Int: PromptSection] = [:]
        for (index, section) in fillOrder {
            guard remaining > 0 else { break }
            let cap = min(section.maxChars, section.content.count, remaining)
            if cap < section.minChars {
                continue
            }
            let truncated = truncate(section.content, toChars: cap, mode: section.truncation)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !truncated.isEmpty else {
                continue
            }
            var copy = section
            copy.content = truncated
            kept[index] = copy
            remaining -= truncated.count
        }

        return sections.indices.compactMap { kept[$0] }
    }

    /// Token-aware variant of `allocate`: the budget and remaining are counted in *estimated tokens*
    /// (via `estimate`) instead of characters, so a base model's real context window is respected more
    /// faithfully than a flat chars-per-token ratio — which matters most for code or non-Latin text,
    /// where that ratio is far from four. Each section's intrinsic `minChars`/`maxChars` still bound
    /// the content itself; the per-section token cap is converted to a character cap using that
    /// content's own character-per-token density, so the character-based `truncate` is reused as is.
    static func allocate(
        _ sections: [PromptSection],
        totalTokens: Int,
        estimate: (String) -> Int
    ) -> [PromptSection] {
        var remainingTokens = max(0, totalTokens)

        let fillOrder = sections.enumerated().sorted { lhs, rhs in
            lhs.element.priority == rhs.element.priority
                ? lhs.offset < rhs.offset
                : lhs.element.priority > rhs.element.priority
        }

        var kept: [Int: PromptSection] = [:]
        for (index, section) in fillOrder {
            guard remainingTokens > 0 else { break }
            let contentTokens = max(1, estimate(section.content))
            let charsPerToken = Double(section.content.count) / Double(contentTokens)
            let remainingChars = Int((Double(remainingTokens) * charsPerToken).rounded(.down))
            let cap = min(section.maxChars, section.content.count, remainingChars)
            if cap < section.minChars {
                continue
            }
            let truncated = truncate(section.content, toChars: cap, mode: section.truncation)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !truncated.isEmpty else {
                continue
            }
            var copy = section
            copy.content = truncated
            kept[index] = copy
            // Clamp: a truncated slice can be token-denser than the section average, so deducting its
            // estimate could drive `remainingTokens` negative and wrongly drop the next section even
            // when it would fit. Floor at zero so over-deduction never reads as a hard stop.
            remainingTokens = max(0, remainingTokens - estimate(truncated))
        }

        return sections.indices.compactMap { kept[$0] }
    }

    /// Truncates `text` to at most `chars`, keeping the start or the end per `mode`. Returns the
    /// input unchanged when it already fits, and the empty string when `chars <= 0`.
    static func truncate(_ text: String, toChars chars: Int, mode: PromptSection.Truncation) -> String {
        guard chars > 0 else { return "" }
        guard text.count > chars else { return text }
        switch mode {
        case .preserveStart:
            return String(text.prefix(chars))
        case .preserveEnd:
            return String(text.suffix(chars))
        }
    }
}
