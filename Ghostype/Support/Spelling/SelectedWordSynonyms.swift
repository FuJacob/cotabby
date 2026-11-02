import Foundation

/// File overview:
/// The pure rules behind "synonyms for the selected word": which selection counts as one word, the
/// few-shot request sent to the user's selected engine, how its comma-separated reply becomes at most
/// nine clean choices in the original word's case, and which keystroke picks one.
///
/// Why the engine and not a thesaurus: macOS ships a thesaurus, but the only public Dictionary
/// Services call (`DCSCopyTextDefinition`) answers from the default dictionary with a definition, not
/// synonyms; reaching the thesaurus needs private `DCS*` functions. The suggestion engine the user
/// already chose (Apple Intelligence, the local model, or their own endpoint) is the simplest source
/// that works without private API, and it sends nothing anywhere the user's suggestions do not
/// already go.
///
/// Everything here is deterministic so it can be unit tested without a model; `SynonymController`
/// owns the live selection, the generation task, and the panel.
enum SelectedWordSynonyms {
    /// At most this many choices, one per digit key 1–9.
    static let maximumChoices = 9

    /// A word shorter than this is rarely worth replacing ("a", "I"), and longer selections are almost
    /// always something other than one word (a URL, an identifier).
    static let wordLengthRange = 2...40

    // MARK: - Trigger

    /// True when `text` is one word: only letters, apostrophes (straight or curly) and hyphens,
    /// 2–40 characters, with at least one letter. Whitespace, digits and other punctuation mean the
    /// selection is a phrase, a number or code, which synonyms do not fit.
    static func isSingleWord(_ text: String) -> Bool {
        guard wordLengthRange.contains(text.count) else { return false }
        return text.contains(where: \.isLetter)
            && text.allSatisfy { $0.isLetter || wordJoiners.contains($0) }
    }

    /// The selected word when `snapshot` may offer synonyms, else nil.
    ///
    /// The resolver blocks every field with a selection for suggestions ("Text is currently
    /// selected."), so that one block reason is allowed here; any other block (secure, credential,
    /// Mail header) or an unsupported field still refuses. App, domain and terminal rules are checked
    /// separately through `SuggestionAvailabilityEvaluator`, the same gate suggestions use.
    static func selectedWord(in snapshot: FocusSnapshot) -> String? {
        switch snapshot.capability {
        case .supported:
            break
        case let .blocked(reason) where reason == FocusCapability.textSelectedReason:
            break
        case .blocked, .unsupported:
            return nil
        }
        guard let context = snapshot.context,
              !context.isSecure,
              context.selection.length > 0,
              isSingleWord(context.selectedText) else {
            return nil
        }
        return context.selectedText
    }

    // MARK: - Request

    /// A few-shot list the model continues with one more comma-separated line. Two examples teach the
    /// format (single words, commas, about five of them) to a base model that cannot follow
    /// instructions; an instruct model reads the same text as an obvious pattern to complete.
    static func prompt(for word: String) -> String {
        "Synonyms for happy: glad, cheerful, joyful, content, pleased\n"
            + "Synonyms for quickly: rapidly, swiftly, fast, promptly, speedily\n"
            + "Synonyms for \(word.lowercased()):"
    }

    /// The engine request for `word`. It reuses the focused field's identity (app, element, focus
    /// sequence) so routing and logs attribute it to the right place, but replaces the field's text
    /// with the few-shot prompt: the user's surrounding text, window title and URL are not sent.
    /// Single-line output and no word range, so the normalizer keeps the whole first line.
    static func request(for word: String, in field: FocusedInputSnapshot) -> SuggestionRequest {
        let prompt = prompt(for: word)
        let promptOnly = FocusedInputSnapshot(
            applicationName: field.applicationName,
            bundleIdentifier: field.bundleIdentifier,
            processIdentifier: field.processIdentifier,
            elementIdentifier: field.elementIdentifier,
            role: field.role,
            subrole: field.subrole,
            caretRect: field.caretRect,
            inputFrameRect: field.inputFrameRect,
            caretSource: field.caretSource,
            caretQuality: field.caretQuality,
            observedCharWidth: nil,
            precedingText: prompt,
            trailingText: "",
            selection: NSRange(location: (prompt as NSString).length, length: 0),
            isSecure: false,
            focusChangeSequence: field.focusChangeSequence
        )
        return SuggestionRequest(
            context: FocusedInputContext(snapshot: promptOnly, generation: 0),
            prefixText: prompt,
            prompt: prompt,
            generation: 0,
            // Nine short words and their commas fit comfortably; a cap keeps a rambling model cheap.
            maxPredictionTokens: 32,
            // Mildly creative so the list has variety, still low enough to stay on topic.
            temperature: 0.3,
            topK: 40,
            topP: 0.9,
            minP: 0.05,
            repetitionPenalty: 1.1,
            randomSeed: nil,
            maxSuffixCharacters: 0,
            completionLengthInstruction: "",
            userName: nil,
            customRules: [],
            languageInstruction: nil,
            clipboardContext: nil,
            visualContextSummary: nil,
            isMultiLineEnabled: false,
            requestID: RequestID.generate()
        )
    }

    // MARK: - Reply

    /// Turns the model's reply into at most nine choices in `original`'s case. Only the first line is
    /// read (a base model often goes on to invent the next "Synonyms for" line). Entries are trimmed
    /// of spaces and end punctuation; empty, multi-word or otherwise non-word entries, the original
    /// word itself, and case-insensitive duplicates are dropped.
    static func parse(_ reply: String, original: String) -> [String] {
        let firstLine = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let originalKey = original.lowercased()
        var seen: Set<String> = [originalKey]
        var choices: [String] = []
        for entry in firstLine.split(separator: ",") {
            let candidate = entry.trimmingCharacters(in: entryTrimmed)
            let key = candidate.lowercased()
            guard isSingleWord(candidate), seen.insert(key).inserted else { continue }
            choices.append(matchingCase(of: original, candidate))
            if choices.count == maximumChoices { break }
        }
        return choices
    }

    /// `synonym` in the case pattern of `original`: ALL CAPS stays all caps, Capitalized stays
    /// capitalized, anything else becomes lower case (models capitalize list items at random, and a
    /// lower-case word in running text is the common case).
    static func matchingCase(of original: String, _ synonym: String) -> String {
        let letters = original.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) {
            return synonym.uppercased()
        }
        let lowered = synonym.lowercased()
        if original.first?.isUppercase == true, let first = lowered.first {
            return first.uppercased() + lowered.dropFirst()
        }
        return lowered
    }

    // MARK: - Presentation and keys

    /// The single-row text shown in the inline preview panel: "1 glad   2 cheerful   3 joyful".
    static func listLabel(_ choices: [String]) -> String {
        choices.enumerated()
            .map { "\($0.offset + 1) \($0.element)" }
            .joined(separator: "   ")
    }

    /// The zero-based choice a keystroke picks: a bare digit 1–9 (top row or keypad, which both type
    /// the digit). Command, Control or Option make it a shortcut rather than a pick, and Shift turns
    /// the top-row digit into a symbol, so `characters` already rules that out.
    static func choiceIndex(characters: String, modifiers: ShortcutModifierMask) -> Int? {
        guard modifiers.isDisjoint(with: [.command, .control, .option]),
              characters.count == 1,
              let digit = characters.first?.wholeNumberValue,
              (1...maximumChoices).contains(digit) else {
            return nil
        }
        return digit - 1
    }

    /// Characters that may join letters inside one word: apostrophes and hyphens.
    private static let wordJoiners: Set<Character> = ["'", "’", "-"]

    /// What surrounds a list entry: spaces and the end punctuation a model puts after the last item.
    private static let entryTrimmed = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".;:!?\"“”()[]"))
}
