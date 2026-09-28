import Foundation

/// File overview:
/// Recognizes a caret that sits right after a valediction ("Best,", "Thanks again," on its own
/// line), the one place in a text where the writer's name is what comes next.
///
/// Why this exists as its own rule: the base-model prompt used to state the writer's name in every
/// preface ("Written by Jacob."), and the live logs showed what a base model does with a salient
/// name whenever the caret text is thin (31 of 2844 generations on 2026-09-10): it introduces the
/// writer at openings ("Hi, I'm Jacob"), addresses them as the recipient ("Thanks for sharing this
/// with us, Jacob"), hands the draft to them as a third party ("forward the draft to Jacob"), or
/// copies the preface wording outright ("This paragraph is written by Jacob"). None of that is what
/// a name is for. At a sign-off the name is exactly the continuation wanted, and there the prefix
/// itself anchors the model, so the persona line is rendered only then.
///
/// Pure and deterministic so the prompt renderer stays testable; `BaseCompletionPromptRenderer` is
/// its only caller today.
enum SignOffCue {
    /// Closing lines a writer follows with their name. Lower-case, punctuation stripped; matched
    /// whole so "I wish you the best" or "thanks, Sam" (already signed) never qualifies.
    static let valedictions: Set<String> = [
        "best", "all the best", "best regards", "best wishes", "with best wishes",
        "kind regards", "kindest regards", "warm regards", "warmest regards", "regards",
        "warmly", "warmest", "sincerely", "sincerely yours", "yours sincerely", "yours truly",
        "yours", "yours faithfully", "faithfully", "truly",
        "cheers", "thanks", "thank you", "thanks again", "thanks so much", "thank you so much",
        "thanks a lot", "thanks a bunch", "many thanks", "much appreciated", "with thanks",
        "with gratitude", "with appreciation", "gratefully", "in gratitude",
        "take care", "talk soon", "speak soon", "see you soon", "until next time",
        "respectfully", "respectfully yours", "cordially", "cordially yours",
        "love", "with love", "much love", "lots of love", "hugs", "xoxo", "xo",
        "peace", "blessings", "god bless"
    ]

    /// True when `prefix` ends in a valediction, so the caret (after its comma, or on the next
    /// line) is where the writer signs.
    static func precedesSignature(_ prefix: String) -> Bool {
        candidates(in: prefix).contains { valedictions.contains(normalized($0)) }
    }

    /// The closing usually sits on its own line, which the prompt prefix keeps as typed
    /// (`SuggestionRequestFactory.lastWords`); it is also found at the end of the last sentence,
    /// for hosts that run lines together: "See you Friday. Thanks," is the same closing as
    /// "See you Friday.\n\nThanks,\n".
    private static func candidates(in text: String) -> [Substring] {
        var found: [Substring] = []
        if let line = lastNonBlankLine(of: text) {
            found.append(line)
        }
        let body = text[...].trimmingCharacters(in: edgeCharacters)[...]
        if let terminator = body.lastIndex(where: { sentenceTerminators.contains($0) }) {
            found.append(body[body.index(after: terminator)...])
        }
        return found
    }

    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    private static func lastNonBlankLine(of text: String) -> Substring? {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Lower-cased with surrounding whitespace, dashes, and closing punctuation removed, and
    /// interior whitespace collapsed, so "Best,", "— Thanks again!" and "kind  regards:" compare
    /// as their words alone.
    private static func normalized(_ line: Substring) -> String {
        let trimmed = line.trimmingCharacters(in: Self.edgeCharacters)
        return trimmed.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static let edgeCharacters: CharacterSet = {
        var set = CharacterSet.whitespaces
        set.formUnion(CharacterSet(charactersIn: ",.!:;-–—~*_\"'()"))
        return set
    }()
}
