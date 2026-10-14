import CoreGraphics
import Foundation

/// File overview:
/// What an answer card shows and what its keys do, as pure values and rules.
///
/// Why pure: these are the two promises answers make to the user before anything leaves their
/// hands. The card names every fact the draft was given, with its sender, conversation, date and
/// app, and marks each one from another conversation, so the user sees what they would disclose
/// (`AnswerAttribution`). And only the user's own click or Tab inserts the draft; it is pasted, never
/// sent (`AnswerCardKeyPolicy`). `AnswerCoordinator` builds the offer and applies the key decisions;
/// `AnswerCardView` renders the offer.

/// A drafted answer, what it answers, and where every one of its facts came from.
nonisolated struct AnswerOffer: Equatable, Sendable {
    struct Source: Equatable, Identifiable, Sendable {
        let id: String
        /// "Sam Rivera · Pilot – Acme · 10 May · Outlook"
        let byline: String
        let excerpt: String
        /// From a conversation other than the one being answered: shown with a warning, since its
        /// people may differ from the one who will read the answer.
        let isFromAnotherConversation: Bool
    }

    let draft: String
    /// Who asked and what, as the card's first line: "Deniz Kaya: How did the pilot go?". If this
    /// is not the message on screen, the user sees it before inserting.
    let answering: String
    let sources: [Source]
}

/// Builds the card's offer from the facts the draft was given.
nonisolated enum AnswerAttribution {
    /// As much of a fact as the model saw (`AnswerPromptRenderer.maximumFactCharacters`), so the
    /// card never hides a part of a fact the draft could use.
    static let maximumExcerptCharacters = AnswerPromptRenderer.maximumFactCharacters
    static let maximumQuestionCharacters = 120
    /// Shown for a conversation with no title, so every fact still names where it came from.
    static let untitledConversation = "untitled conversation"

    /// The conversation an answer replies in, when known; facts from anywhere else are "other".
    struct Conversation: Equatable, Sendable {
        let source: String
        let conversationID: String
    }

    /// One source per fact the model saw, calendar facts first, in prompt order: none is left off.
    static func offer(
        draft: String, answering: String, calendarFacts: [AnswerPromptRenderer.Fact],
        hits: [MemorySearchResult.Hit], current: Conversation?
    ) -> AnswerOffer {
        let calendarSources: [AnswerOffer.Source] = calendarFacts.map { (fact: AnswerPromptRenderer.Fact) in source(fact) }
        let memorySources: [AnswerOffer.Source] = hits.map { (hit: MemorySearchResult.Hit) in
            source(hit, otherConversation: isOther(hit, current: current))
        }
        return AnswerOffer(draft: draft, answering: answering, sources: calendarSources + memorySources)
    }

    /// The card's "what it answers" line: "Asker: question", on one line and clipped.
    static func answeringLine(asker: String?, question: String) -> String {
        let asked = AnswerPromptRenderer.oneLine(question)
        let clipped = asked.count > maximumQuestionCharacters ? String(asked.prefix(maximumQuestionCharacters)) + "…" : asked
        let who = AnswerPromptRenderer.oneLine(asker ?? "")
        return who.isEmpty ? clipped : "\(who): \(clipped)"
    }

    static func isOther(_ hit: MemorySearchResult.Hit, current: Conversation?) -> Bool {
        hit.source != current?.source || hit.conversationId != current?.conversationID
    }

    static func source(_ fact: AnswerPromptRenderer.Fact) -> AnswerOffer.Source {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        let byline = [AvailabilityFacts.title, formatter.string(from: fact.timestamp)].joined(separator: " · ")
        return AnswerOffer.Source(id: "calendar:\(Int(fact.timestamp.timeIntervalSince1970))", byline: byline,
                                  excerpt: String(fact.text.prefix(maximumExcerptCharacters)), isFromAnotherConversation: false)
    }

    /// "Sender · Conversation · date · App": the sender ("You" for the user's own), the
    /// conversation (or "untitled conversation"), and the app, always.
    static func source(_ hit: MemorySearchResult.Hit, otherConversation: Bool) -> AnswerOffer.Source {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        let app = MemorySourceCatalog.descriptor(hit.source)?.title ?? hit.source
        let who = hit.isFromMe ? "You" : (hit.sender.isEmpty ? "Someone" : hit.sender)
        let conversation = hit.conversationTitle.isEmpty ? untitledConversation : hit.conversationTitle
        let byline = [who, conversation, formatter.string(from: Date(timeIntervalSince1970: hit.timestamp)), app]
            .joined(separator: " · ")
        let excerpt = AnswerPromptRenderer.oneLine(hit.text)
        return AnswerOffer.Source(id: hit.recordId, byline: byline, excerpt: String(excerpt.prefix(maximumExcerptCharacters)),
                                  isFromAnotherConversation: otherConversation)
    }
}

/// What a key press does while an answer card is up. Only an unmodified Tab in an empty reply
/// inserts (a click is the other way); Esc dismisses; every other key, Return included, reaches the
/// app untouched and withdraws the card, so the user is writing their own reply. Nothing here ever
/// sends a message.
nonisolated enum AnswerCardKeyPolicy {
    enum Action: Equatable {
        case insert
        case dismiss
        case passAndWithdraw
        /// No card is up: the key is not the card's business at all.
        case pass
    }

    static let tabKeyCode: CGKeyCode = 48
    static let escapeKeyCode: CGKeyCode = 53

    static func action(keyCode: CGKeyCode, flags: CGEventFlags, tabInserts: Bool, cardShown: Bool) -> Action {
        // A card only exists for a reply field answers run in (`IncomingMessageResolver.answersIn`);
        // without one, Tab and every other key belong to the app.
        guard cardShown else { return .pass }
        let plain = flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if keyCode == tabKeyCode, plain, tabInserts { return .insert }
        if keyCode == escapeKeyCode { return .dismiss }
        return .passAndWithdraw
    }

    /// Whether the draft may be pasted now: the focused field and the frontmost app are both the
    /// app the card was offered in. A focus snapshot can lag behind an app switch, so the frontmost
    /// app is checked too; otherwise the card is dropped and nothing is inserted.
    static func mayInsert(cardBundleIdentifier: String, focusedBundleIdentifier: String, frontmostBundleIdentifier: String?) -> Bool {
        focusedBundleIdentifier == cardBundleIdentifier && frontmostBundleIdentifier == cardBundleIdentifier
    }

    /// The text pasted at the caret: the draft (without its own salutation when the user already
    /// typed one), with no trailing line break, so pasting never adds a Return a chat app could act on.
    static func insertionText(draft: String, precedingText: String) -> String {
        let hasSalutation = !precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let text = hasSalutation ? ReplyFieldEmptiness.bodyAfterSalutation(draft) : draft
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
