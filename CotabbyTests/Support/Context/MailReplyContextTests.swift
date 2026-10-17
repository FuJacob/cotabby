import XCTest
@testable import Cotabby

/// Pins what a mail reply contributes to a suggestion: the quoted thread after the caret, its
/// subject as the conversation's name, its sender as the addressee, and screen text from the
/// compose column only.
final class MailReplyContextTests: XCTestCase {
    /// What Outlook's inline reply exposes after the caret when the user follows up on their own
    /// mail: the quoted header, then the message.
    private let outlookReplyTail = """


    From: Alex Morgan <alex@example.com>
    Date: Wednesday, 7 October 2026 at 16:14
    To: Priya Shah <priya@example.com>; Jordan Lee <jordan@example.com>
    Cc: Sam Rivera <sam@example.com>
    Subject: Re: Q3 rollout plan

    Since the export job can now run nightly, we could move the cutover to Friday..
    """

    // MARK: - Subject

    func test_readsTheSubjectFromOutlooksQuotedHeader() {
        XCTAssertEqual(MailReplyContext.quotedSubject(in: outlookReplyTail), "Re: Q3 rollout plan")
        XCTAssertNil(QuotedReplyParser.quotedSubject(in: "Kimden: Deniz\nKonu: Teklif\n\nNe durumda?"),
                     "a block with no sender address is not a header the shared parser accepts")
    }

    func test_noSubjectWithoutAQuotedHeader() {
        XCTAssertNil(MailReplyContext.quotedSubject(in: ""))
        XCTAssertNil(MailReplyContext.quotedSubject(in: "the rest of my own paragraph"))
        // Mail's attribution quote names no subject; its compose window title already does.
        XCTAssertNil(MailReplyContext.quotedSubject(in: "On 7 Oct 2026, at 16:14, Ayşe wrote:\n> Hi"))
    }

    func test_aSubjectLineAfterTheHeaderBlockIsNotTheThreadsSubject() {
        let tail = "From: Ayşe <a@example.com>\nTo: Alex\n\nSubject: this line is part of her message"
        XCTAssertNil(MailReplyContext.quotedSubject(in: tail))
    }

    // MARK: - Recipient

    /// Outlook's quoted header when the user replies to someone else.
    private let replyToJordanTail = """


    From: Jordan Lee <jordan@example.com>
    Date: Sunday, 11 October 2026 at 12:35
    To: Alex Morgan <alex@example.com>; Priya Shah <priya@example.com>
    Subject: Clarification required

    Hi Alex/Priya,

    I have several questions/concerns that I'd like to have addressed.
    """

    func test_theRecipientIsTheQuotedMessagesSender() {
        XCTAssertEqual(MailReplyContext.replyRecipient(in: replyToJordanTail, userName: "Alex"), "Jordan Lee")
        XCTAssertEqual(MailReplyContext.replyRecipient(in: replyToJordanTail, userName: nil), "Jordan Lee")
        XCTAssertEqual(
            MailReplyContext.replyRecipient(in: "On 7 Oct 2026, at 16:14, Ayşe Yılmaz <a@example.com> wrote:\n> Hi", userName: "Alex"),
            "Ayşe Yılmaz"
        )
    }

    func test_noRecipientForTheUsersOwnMailABareAddressOrNoQuote() {
        // A follow-up to the user's own message goes to someone else; naming the user is the bug.
        XCTAssertNil(MailReplyContext.replyRecipient(in: outlookReplyTail, userName: "Alex"))
        XCTAssertNil(MailReplyContext.replyRecipient(in: outlookReplyTail, userName: "alex morgan"))
        XCTAssertNil(MailReplyContext.replyRecipient(in: "From: <a@example.com>\nSubject: Hi\n\nHello there", userName: nil))
        XCTAssertNil(MailReplyContext.replyRecipient(in: "the rest of my own paragraph", userName: "Alex"))
    }

    func test_anOutlookReplyPromptNamesWhoItIsAddressedTo() {
        let context = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.microsoft.Outlook", precedingText: "Dear ",
            trailingText: replyToJordanTail, windowTitle: "Inbox • All Accounts"
        )
        let settings = CotabbyTestFixtures.settingsSnapshot(selectedEngine: .llamaOpenSource, userName: "Alex")
        let prompt = SuggestionRequestFactory.buildRequest(context: context, settings: settings, configuration: .standard)
            .request.prompt
        XCTAssertTrue(prompt.hasSuffix("\n\nTo: Jordan Lee\n\nDear "), prompt)

        // Outside mail the trailing text is the user's own paragraph, never an addressee.
        let notes = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.apple.TextEdit", precedingText: "Dear ", trailingText: replyToJordanTail
        )
        XCTAssertFalse(SuggestionRequestFactory.buildRequest(context: notes, settings: settings, configuration: .standard)
            .request.prompt.contains("To: Jordan Lee"))
    }

    // MARK: - Budgets and titles

    func test_mailAppsCarryTheQuotedThreadOtherAppsKeepTheDefault() {
        XCTAssertEqual(MailReplyContext.trailingBudget(bundleIdentifier: "com.microsoft.Outlook", defaultBudget: 192), 1500)
        XCTAssertEqual(MailReplyContext.trailingBudget(bundleIdentifier: "com.apple.mail", defaultBudget: 192), 1500)
        XCTAssertEqual(MailReplyContext.trailingBudget(bundleIdentifier: "com.apple.TextEdit", defaultBudget: 192), 192)
    }

    func test_outlooksFolderWindowTitlesAreMailboxesNotConversations() {
        XCTAssertTrue(MailReplyContext.isMailboxWindowTitle("Inbox • All Accounts", bundleIdentifier: "com.microsoft.Outlook"))
        XCTAssertFalse(MailReplyContext.isMailboxWindowTitle("Re: Q3 rollout plan", bundleIdentifier: "com.microsoft.Outlook"))
        XCTAssertFalse(MailReplyContext.isMailboxWindowTitle("Inbox • All Accounts", bundleIdentifier: "com.apple.mail"))
    }

    // MARK: - Memory scope

    /// Mail gets no memory scope at all (#871): neither the mailbox window title nor a reply's own
    /// window, whatever its quote says.
    func test_mailGetsNoMemoryScope() {
        let sources = ["com.microsoft.Outlook": ["outlook"]]
        XCTAssertNil(ConversationScopeResolver.scope(
            bundleIdentifier: "com.microsoft.Outlook", conversationTitle: "Inbox • All Accounts", sourcesByBundle: sources
        ))
        XCTAssertNil(ConversationScopeResolver.scope(
            bundleIdentifier: "com.microsoft.Outlook", conversationTitle: "Re: Q3 rollout plan", sourcesByBundle: sources
        ))
    }

    // MARK: - Request

    func test_anOutlookReplyPromptCarriesTheThreadAndItsSubject() {
        let context = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.microsoft.Outlook", precedingText: "Dear P",
            trailingText: outlookReplyTail, windowTitle: "Inbox • All Accounts"
        )
        let request = SuggestionRequestFactory.buildRequest(
            context: context, settings: CotabbyTestFixtures.settingsSnapshot(selectedEngine: .llamaOpenSource),
            configuration: .standard
        ).request
        XCTAssertTrue(request.prompt.contains("Since the export job can now run nightly"))
        XCTAssertTrue(request.prompt.contains("Re: Q3 rollout plan"))
        XCTAssertFalse(request.prompt.contains("Inbox • All Accounts"))
        XCTAssertTrue(request.prompt.hasSuffix("Dear P"))
    }

    /// The thread, its subject and its sender all come from the text after the caret, which never
    /// reaches the endpoint backend; the endpoint's request keeps the window title it always had.
    func test_theEndpointGetsNothingReadFromTheQuotedThread() {
        let context = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.microsoft.Outlook", precedingText: "Dear ",
            trailingText: replyToJordanTail, windowTitle: "Inbox • All Accounts"
        )
        let settings = CotabbyTestFixtures.settingsSnapshot(selectedEngine: .openAICompatible, userName: "Alex")
        let request = SuggestionRequestFactory.buildRequest(context: context, settings: settings, configuration: .standard).request
        XCTAssertNil(request.surfaceContext?.replyingTo)
        XCTAssertFalse(request.prompt.contains("Jordan"))
        XCTAssertFalse(request.prompt.contains("Clarification required"))
    }

    // MARK: - Condensed thread

    /// A typical quoted thread holds a few sentences of message among headers, addresses,
    /// signatures and a footer. The prompt gets who said what, and nothing else.
    func test_aQuotedThreadIsCondensedToWhoSaidWhat() {
        let tail = """


        From: Deniz Kaya <deniz@example.com>
        Date: Wednesday, 7 October 2026 at 10:33
        To: Emre Demir <emre@example.org>
        Cc: Selin Aydın <selin@example.org>; Alex Morgan <alex@example.com>
        Subject: Re: Lisans Süresi

        Tamamdır. Teşekkürler.\u{20}

        \u{20}
        DENIZ

        HEAD OF OPERATIONS

         WhatsApp
        example.com | LinkedIn

        From: Emre Demir <emre@example.org>
        Date: Wednesday, 7 October 2026 at 08:11
        To: Deniz Kaya <deniz@example.com>
        Subject: YNT: Lisans Süresi

        Merhabalar,

        Eğitimin temel seviyesi olması yeterli olacaktır. Akabinde oluşan soruları ayrıca konuşuruz.

        Saygılarımla

        Emre Demir
        Takım Lideri | Destek
        +1 555 010 0199
        """
        XCTAssertEqual(
            MailReplyContext.condensedThread(tail),
            "Deniz Kaya: Tamamdır. Teşekkürler.\n\n"
                + "Emre Demir: Merhabalar, Eğitimin temel seviyesi olması yeterli olacaktır. Akabinde oluşan soruları ayrıca konuşuruz."
        )
    }

    func test_textWithoutAQuoteIsLeftAsItIs() {
        XCTAssertEqual(MailReplyContext.condensedThread("the rest of my paragraph"), "the rest of my paragraph")
    }

    // MARK: - Screen text

    func test_mailScreenTextKeepsTheComposeColumnAndDropsTheMessageList() {
        let focus = CGRect(x: 0.4, y: 0.4, width: 0.55, height: 0.3)
        let lines = [
            OCRTextHygiene.OCRLine(text: "Subject Re Q3 rollout plan", confidence: 1,
                                   boundingBox: CGRect(x: 0.42, y: 0.8, width: 0.3, height: 0.03)),
            OCRTextHygiene.OCRLine(text: "Dear Morgan and Riley As agreed during our call", confidence: 1,
                                   boundingBox: CGRect(x: 0.05, y: 0.75, width: 0.3, height: 0.03))
        ]
        let mail = VisualContextExcerptSelector.select(
            lines: lines, fieldText: "", focusBounds: focus, maxCharacters: 4000, keepsOnlyFieldColumn: true
        )
        XCTAssertEqual(mail, "Subject Re Q3 rollout plan")
        let other = VisualContextExcerptSelector.select(lines: lines, fieldText: "", focusBounds: focus, maxCharacters: 4000)
        XCTAssertTrue(other.contains("Morgan"), "Other apps keep neighbouring columns")
    }

    // MARK: - Review fixes

    /// A greeting is not the message: the short line after it is what was said, not a signature.
    /// A sentence that mentions a link is message too; only a bare link or address line is dropped.
    func test_shortBodiesAndSentencesWithLinksStay() {
        let tail = """


        From: Jordan Lee <jordan@example.com>
        Subject: Re: Pilot

        Hi Alex,
        The pilot is approved
        Please review https://example.com/report before Friday.
        https://example.com/unsubscribe
        """
        XCTAssertEqual(
            MailReplyContext.condensedThread(tail),
            "Jordan Lee: Hi Alex, The pilot is approved Please review https://example.com/report before Friday."
        )
    }

    /// An Outlook-classic quote opens with a rule line and then its From block: one message, read once.
    func test_anOriginalMessageQuoteIsReadOnce() {
        let tail = """


        -----Original Message-----
        From: Jordan Lee <jordan@example.com>
        Sent: Monday, 5 October 2026 09:10
        Subject: Re: Pilot

        Is the pilot approved?
        """
        XCTAssertEqual(MailReplyContext.condensedThread(tail), "Jordan Lee: Is the pilot approved?")
    }

    /// Apple Intelligence gets the condensed thread too, not the raw 1500 characters of headers.
    func test_appleIntelligenceGetsTheCondensedThread() {
        let context = CotabbyTestFixtures.focusedInputContext(
            bundleIdentifier: "com.microsoft.Outlook", precedingText: "Dear ",
            trailingText: replyToJordanTail, windowTitle: "Inbox • All Accounts"
        )
        let settings = CotabbyTestFixtures.settingsSnapshot(selectedEngine: .appleIntelligence, userName: "Alex")
        let request = SuggestionRequestFactory.buildRequest(context: context, settings: settings, configuration: .standard).request
        let prompt = FoundationModelPromptRenderer.prompt(for: request)
        XCTAssertTrue(prompt.contains("Jordan Lee: Hi Alex/Priya,"), prompt)
        XCTAssertFalse(prompt.contains("priya@example.com"), "header lines and addresses are condensed away")
    }
}
