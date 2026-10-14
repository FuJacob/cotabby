import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Pins answers' two promises to the user: the card names every fact the draft was given, marking
/// each one from another conversation with its app and conversation, and only the user's own click
/// or Tab inserts the draft, which is pasted, never sent.
final class AnswerOfferTests: XCTestCase {
    private func hit(_ id: String, source: String = "outlook", conversation: String, title: String,
                     sender: String = "Sam Rivera", text: String = "The pilot passed.") -> MemorySearchResult.Hit {
        MemorySearchResult.Hit(
            recordId: id, source: source, conversationId: conversation, conversationTitle: title, sender: sender,
            isFromMe: false, timestamp: 1_790_000_000, subject: nil, text: text, score: 1, similarity: 0.8, via: "both"
        )
    }

    // MARK: - Attribution

    func test_everyFactIsOnTheCardAndOtherConversationsAreMarkedWithTheirAppAndConversation() {
        let current = AnswerAttribution.Conversation(source: "teams", conversationID: "dm-deniz")
        let hits = [
            hit("1", source: "teams", conversation: "dm-deniz", title: "Deniz Kaya"),
            hit("2", conversation: "pilot", title: "Pilot - Acme"),
            hit("3", source: "teams", conversation: "ops", title: ""),
            hit("4", conversation: "x", title: "Board"),
            hit("5", conversation: "y", title: "Budget")
        ]
        let answering = AnswerAttribution.answeringLine(asker: "Deniz Kaya", question: "How did\nthe pilot go?")
        let offer = AnswerAttribution.offer(draft: "It passed.", answering: answering, calendarFacts: [], hits: hits, current: current)
        XCTAssertEqual(offer.sources.count, hits.count, "no fact the model saw is left off the card")
        XCTAssertEqual(offer.sources.map(\.isFromAnotherConversation), [false, true, true, true, true])
        XCTAssertTrue(offer.sources[1].byline.contains("Pilot - Acme") && offer.sources[1].byline.contains("Outlook"))
        XCTAssertTrue(offer.sources[2].byline.contains(AnswerAttribution.untitledConversation))
        XCTAssertTrue(offer.sources[2].byline.contains("Microsoft Teams"))
        XCTAssertEqual(offer.answering, "Deniz Kaya: How did the pilot go?")
    }

    func test_withoutAnIdentifiedConversationEveryFactIsAnotherConversations() {
        let offer = AnswerAttribution.offer(draft: "Yes.", answering: AnswerAttribution.answeringLine(asker: nil, question: "Is it done?"),
                                            calendarFacts: [], hits: [hit("1", conversation: "pilot", title: "Pilot - Acme")], current: nil)
        XCTAssertEqual(offer.sources.map(\.isFromAnotherConversation), [true])
        XCTAssertEqual(offer.answering, "Is it done?")
    }

    // MARK: - Keys and insertion

    func test_onlyAPlainTabInAnEmptyReplyInserts() {
        XCTAssertEqual(AnswerCardKeyPolicy.action(keyCode: 48, flags: [], tabInserts: true, cardShown: true), .insert)
        XCTAssertEqual(AnswerCardKeyPolicy.action(keyCode: 48, flags: [], tabInserts: false, cardShown: true), .passAndWithdraw,
                       "after a salutation Tab belongs to ghost text; only a click inserts")
        XCTAssertEqual(AnswerCardKeyPolicy.action(keyCode: 48, flags: .maskShift, tabInserts: true, cardShown: true), .passAndWithdraw)
        XCTAssertEqual(AnswerCardKeyPolicy.action(keyCode: 53, flags: [], tabInserts: true, cardShown: true), .dismiss)
        // Return and Enter never insert or send: they reach the app and the card goes away.
        XCTAssertEqual(AnswerCardKeyPolicy.action(keyCode: 36, flags: [], tabInserts: true, cardShown: true), .passAndWithdraw)
        XCTAssertEqual(AnswerCardKeyPolicy.action(keyCode: 76, flags: [], tabInserts: true, cardShown: true), .passAndWithdraw)
        XCTAssertEqual(AnswerCardKeyPolicy.action(keyCode: 0, flags: [], tabInserts: true, cardShown: true), .passAndWithdraw)
        // No card (withdrawn, or never offered): every key, Tab included, is the app's.
        XCTAssertEqual(AnswerCardKeyPolicy.action(keyCode: 48, flags: [], tabInserts: true, cardShown: false), .pass)
    }

    /// A lagging focus snapshot must not paste into another app: the frontmost app has to be the
    /// card's app too, and without a known frontmost app nothing is inserted.
    func test_aDraftIsPastedOnlyIntoTheAppTheCardWasOfferedIn() {
        XCTAssertTrue(AnswerCardKeyPolicy.mayInsert(cardBundleIdentifier: "com.microsoft.Outlook",
                                                    focusedBundleIdentifier: "com.microsoft.Outlook",
                                                    frontmostBundleIdentifier: "com.microsoft.Outlook"))
        XCTAssertFalse(AnswerCardKeyPolicy.mayInsert(cardBundleIdentifier: "com.microsoft.Outlook",
                                                     focusedBundleIdentifier: "com.microsoft.Outlook",
                                                     frontmostBundleIdentifier: "com.google.Chrome"),
                       "the snapshot still says Outlook, but Chrome is in front")
        XCTAssertFalse(AnswerCardKeyPolicy.mayInsert(cardBundleIdentifier: "com.microsoft.Outlook",
                                                     focusedBundleIdentifier: "com.google.Chrome",
                                                     frontmostBundleIdentifier: "com.google.Chrome"))
        XCTAssertFalse(AnswerCardKeyPolicy.mayInsert(cardBundleIdentifier: "com.microsoft.Outlook",
                                                     focusedBundleIdentifier: "com.microsoft.Outlook",
                                                     frontmostBundleIdentifier: nil))
    }

    func test_insertedTextNeverEndsInALineBreakOrRepeatsTheSalutation() {
        XCTAssertEqual(AnswerCardKeyPolicy.insertionText(draft: "Yes, it passed.\n\n", precedingText: ""), "Yes, it passed.")
        XCTAssertEqual(AnswerCardKeyPolicy.insertionText(draft: "Hi Deniz,\n\nYes, it passed.\n", precedingText: "Dear Deniz,\n\n"),
                       "Yes, it passed.")
    }
}
