import Foundation

/// File overview:
/// Decides whether a message someone sent the user asks them something, and which sentences ask it.
///
/// Why heuristics and not a model: this runs every time a reply field is focused, must cost nothing,
/// and its mistakes are cheap in one direction only (a missed question just means no card; a false
/// one means a card the user dismisses with a keystroke, and the grounding check usually drops it
/// anyway because memory holds no answer to a statement). It covers English and Turkish:
///
/// - English: a question mark; or, in a sentence without a closing period (chat style), an
///   interrogative opener ("what", "when", "can you", "do we", "any update on", …); or a request
///   ("let me know", "please confirm", "could you send", "I would like to", "thanks in advance").
///   Mail asks mostly by request, not by question: "I would like to get trial licenses before the
///   scope is final." expects an answer as much as a question does.
/// - Turkish: a question mark; the question particles (`mı mi mu mü` and their personal forms,
///   written apart from the word as Turkish spelling requires); question words ("ne zaman",
///   "nerede", "nasıl", "kaç", …); or a request ("haber ver", "bilgi verir").
///
/// Returns the asking sentences (at most two, the latest ones), so the answer is drafted for what
/// was asked, not for the greeting around it. Pure; used by `AnswerCoordinator`.
nonisolated enum QuestionDetector {
    static let maximumSentences = 2

    static func question(in message: String) -> String? {
        let sentences = Self.sentences(message)
        let asking = sentences.filter(isQuestion)
        guard !asking.isEmpty else { return nil }
        return asking.suffix(maximumSentences).joined(separator: " ")
    }

    static func isQuestion(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        guard words.count >= 2 else { return false }
        if let last = trimmed.last, "?؟".contains(last) { return true }
        if trimmed.hasPrefix("¿") || words.contains(where: turkishParticles.contains) { return true }
        let text = " " + words.joined(separator: " ") + " "
        if (turkishPhrases + requestPhrases).contains(where: { text.contains(" \($0) ") }) { return true }
        return !trimmed.hasSuffix(".") && opensLikeAnEnglishQuestion(words)
    }

    /// An English opener counts only without a closing period (checked by the caller): "Can you
    /// send it" is a question in chat, "Can is coming tomorrow." is a statement about Can.
    private static func opensLikeAnEnglishQuestion(_ words: [String]) -> Bool {
        guard let first = words.first, englishOpeners.contains(first) else { return false }
        return !(first == "can" && words.count > 1 && !englishSubjects.contains(words[1]))
    }

    /// Sentences, split after `.`, `!`, `?` and line breaks, keeping their punctuation. A period
    /// between digits is part of a number or a date ("3.11", "4.000"), not the end of a sentence.
    static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isNewline {
                sentences.append(current)
                current = ""
                continue
            }
            current.append(character)
            let joinsDigits = character == "." && index > 0 && index + 1 < characters.count
                && characters[index - 1].isNumber && characters[index + 1].isNumber
            if ".!?؟".contains(character), !joinsDigits {
                sentences.append(current)
                current = ""
            }
        }
        sentences.append(current)
        return sentences.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static let turkishParticles: Set<String> = [
        "mı", "mi", "mu", "mü",
        "mısın", "misin", "musun", "müsün", "mısınız", "misiniz", "musunuz", "müsünüz",
        "mıyız", "miyiz", "muyuz", "müyüz", "mıydı", "miydi", "muydu", "müydü",
        "mıdır", "midir", "mudur", "müdür", "mıyım", "miyim", "muyum", "müyüm"
    ]

    private static let turkishPhrases: [String] = [
        "ne zaman", "nerede", "nereye", "neden", "niye", "nasıl", "hangi", "kaç", "kim", "kime", "kimin",
        "ne oldu", "ne durumda", "haber ver", "haber verir", "bilgi ver", "bilgi verir", "bilgi verebilir",
        "dönüş yap", "dönüş yapabilir", "lütfen", "rica ederim", "rica ediyorum", "yardımcı olabilir"
    ]

    private static let requestPhrases: [String] = [
        "let me know", "please confirm", "please advise", "please share", "please send", "please let",
        "could you", "can you", "would you", "will you", "do you know", "any update", "any news",
        "any idea", "any thoughts", "what about", "how about",
        "please", "kindly", "i would like", "i'd like", "we would like", "we'd like", "i need", "we need",
        "would be great if", "would be helpful", "would appreciate", "thanks in advance",
        "thank you in advance"
    ]

    private static let englishOpeners: Set<String> = [
        "what", "when", "where", "who", "whom", "whose", "why", "how", "which",
        "can", "could", "would", "will", "shall", "should", "do", "does", "did",
        "is", "are", "was", "were", "have", "has", "had", "may", "any"
    ]

    /// Words that follow "can" in a question ("can you", "can we"), as opposed to the name Can.
    private static let englishSubjects: Set<String> = [
        "i", "you", "we", "they", "he", "she", "it", "someone", "anyone", "this", "that", "the"
    ]
}

/// Whether a reply field is still empty, for drafting an answer into it.
///
/// A chat composer is empty when it holds no text. A mail reply never is: below the caret sit the
/// user's signature and the quoted message being answered. So: nothing before the caret, and after
/// it only whitespace, or a short signature followed by the client's quote header as the strict
/// shared parser reads it (`MailQuoteHeader`).
///
/// Mail replies usually start with a salutation the user types before thinking about the answer
/// ("Dear Jordan,"), so `isAwaitingBody` also accepts a reply holding only that line, with the caret
/// on a fresh line below it, which is where the answer goes.
nonisolated enum ReplyFieldEmptiness {
    static let maximumSignatureLines = 8
    static let maximumSignatureCharacters = 400
    static let maximumSalutationCharacters = 60

    static func isEmpty(precedingText: String, trailingText: String) -> Bool {
        guard precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return holdsOnlySignatureAndQuote(precedingText: precedingText, trailingText: trailingText)
    }

    /// After the caret: nothing, or a short signature and then the client's quote header, as the
    /// strict shared parser reads it (`MailQuoteHeader`).
    private static func holdsOnlySignatureAndQuote(precedingText: String, trailingText: String) -> Bool {
        if trailingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let header = MailQuoteHeader.client(precedingText: precedingText, trailingText: trailingText) else { return false }
        let signature = header.linesAboveHeader.filter { !$0.isEmpty }
        return signature.count <= maximumSignatureLines && signature.joined(separator: "\n").count <= maximumSignatureCharacters
    }

    /// Empty, or holding only a salutation line with the caret on a line of its own below it.
    static func isAwaitingBody(precedingText: String, trailingText: String) -> Bool {
        guard holdsOnlySignatureAndQuote(precedingText: precedingText, trailingText: trailingText) else { return false }
        let before = precedingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if before.isEmpty { return true }
        let caretLine = precedingText.reversed().prefix { !$0.isNewline }
        return isSalutation(before) && caretLine.allSatisfy(\.isWhitespace) && precedingText.contains(where: \.isNewline)
    }

    /// A single short greeting line: "Dear Jordan,", "Hi team!", "Merhaba Deniz Bey,", "Hello".
    static func isSalutation(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumSalutationCharacters, !text.contains(where: \.isNewline) else { return false }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let first = words.first else { return false }
        let opener = salutationOpeners.contains(first)
            || (words.count > 1 && salutationOpeners.contains(first + " " + words[1]))
        // Closing punctuation, or a bare "Hi Sam": a longer unpunctuated line is already the body.
        return opener && (text.hasSuffix(",") || text.hasSuffix("!") || words.count <= 4)
    }

    /// The draft without its own salutation, for a reply whose salutation the user already typed.
    static func bodyAfterSalutation(_ draft: String) -> String {
        let lines = draft.components(separatedBy: .newlines)
        guard let first = lines.first, isSalutation(first) else { return draft }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let salutationOpeners: Set<String> = [
        "dear", "hi", "hello", "hey", "greetings", "good morning", "good afternoon", "good evening",
        "merhaba", "sayın", "selam", "değerli", "beste", "geachte", "hallo", "bonjour", "hola", "ciao"
    ]
}
