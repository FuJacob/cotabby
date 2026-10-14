import Foundation
import Logging

/// File overview:
/// Finds the latest message the user received in the conversation whose reply field is focused.
///
/// Where it comes from, freshest source first:
/// - **Mail replies** whose field exposes the quoted original below the caret (Outlook): read
///   through Accessibility as the field's trailing text, by the one strict reader
///   (`QuotedReplyParser.quotedMessage`, over `MailQuoteHeader`). No sync is needed. The quote is
///   data only: it says what is asked and by whom, never which remembered thread the answer is in
///   (`quotedIncoming`). A mail reply without that quote (Apple Mail) gets no answer.
/// - **Chats with a memory source** (Teams): the conversation is the one Cotabby identifies from
///   the window, as memory's search does (`ConversationScopeResolver`); the source is synced first
///   (a delta read, throttled), exactly one conversation must match, and the newest messages are
///   read from memory. Consecutive incoming messages at the end are taken together, so "Hi!"
///   followed by the actual question counts as one. If the newest message is the user's own, they
///   have already replied and there is nothing to answer. A window whose title names no
///   conversation (WhatsApp's is just "WhatsApp") gets no answer.
///
/// Security rule: the sender of a message never chooses which conversation an answer treats as its
/// own. Message content (a quoted subject, a display name, quoted text) is never a scope; a mail
/// answer has no conversation of its own at all, and anything ambiguous gives no answer.
///
/// Which conversation a question is read from is independent of which sources may supply facts for
/// the answer: WhatsApp can be off as an answer source and still be where a question arrives.
/// Owned by `AnswerCoordinator`.
@MainActor
final class IncomingMessageResolver {
    nonisolated struct IncomingMessage: Equatable, Sendable {
        let text: String
        let sender: String?
        /// The conversation in memory: the chat Cotabby identified from the window; never for mail.
        let conversation: MemoryConversation?
        /// The incoming messages' own records, never to be offered as facts for their own answer.
        let recordIDs: Set<String>
        /// Identifies the message for caching and dismissal, so the same message gets one draft and
        /// one dismissal, and another message with the same words ("Any update?") is its own:
        /// `mailKey` or `chatKey`.
        let key: String
    }

    /// A quoted mail's identity: who sent it (address, else name), its subject and date line as
    /// the header gives them, and its body.
    nonisolated static func mailKey(_ quoted: QuotedReplyParser.QuotedMessage, subject: String?) -> String {
        let sender = quoted.senderAddress ?? quoted.sender ?? ""
        return ["mail", sender, subject ?? "", quoted.sentLine ?? "", quoted.body].joined(separator: "\u{1f}")
    }

    /// A chat burst's identity: its conversation and its own message records.
    nonisolated static func chatKey(conversation: MemoryConversation, recordIDs: Set<String>) -> String {
        (["chat", conversation.source, conversation.conversationId] + recordIDs.sorted()).joined(separator: "\u{1f}")
    }

    private let engine: @MainActor () -> MemoryEngine?
    private let historySync: MemoryHistorySync
    private let sourcesByBundle: @MainActor () -> [String: [String]]
    private var lastSync: [String: Date] = [:]

    /// Sources whose newest messages are read from memory (synced on demand).
    nonisolated static let chatSources: Set<String> = ["whatsapp", "teams"]
    /// A chat source is synced at most this often for answers (the periodic sync covers the rest).
    nonisolated static let syncInterval: TimeInterval = 20
    /// Incoming messages taken together at the end of a chat.
    nonisolated static let maximumIncomingRun = 3

    init(engine: @escaping @MainActor () -> MemoryEngine?, historySync: MemoryHistorySync,
         sourcesByBundle: @escaping @MainActor () -> [String: [String]]) {
        self.engine = engine
        self.historySync = historySync
        self.sourcesByBundle = sourcesByBundle
    }

    /// See `AnswerDraftEngine`: released through a nonisolated deinit.
    nonisolated deinit {}

    /// Whether answers run in an app at all: mail apps, and apps with an enabled chat memory source.
    func answersIn(bundleIdentifier: String) -> Bool {
        Self.answersIn(bundleIdentifier: bundleIdentifier, sourcesByBundle: sourcesByBundle())
    }

    /// Answers run only where a message someone sent the user is identified by the app itself: a
    /// mail app's reply (`ConversationScopeResolver.mailBundleIdentifiers`), or a chat app whose
    /// memory source is on (Teams, WhatsApp). Never a browser page or another app's field, whose
    /// text after the caret a page or a remote party can shape like a quoted mail; a draft pasted
    /// there would reach whoever controls it.
    nonisolated static func answersIn(bundleIdentifier: String, sourcesByBundle: [String: [String]]) -> Bool {
        ConversationScopeResolver.mailBundleIdentifiers.contains(bundleIdentifier)
            || (sourcesByBundle[bundleIdentifier] ?? []).contains(where: chatSources.contains)
    }

    func latestIncoming(for context: FocusedInputSnapshot) async -> IncomingMessage? {
        guard answersIn(bundleIdentifier: context.bundleIdentifier) else { return nil }
        let isMail = ConversationScopeResolver.mailBundleIdentifiers.contains(context.bundleIdentifier)
        // A quote below the caret is read only in a mail app: anywhere else it is just text.
        if isMail, let quoted = QuotedReplyParser.quotedMessage(precedingText: context.precedingText, trailingText: context.trailingText) {
            return Self.quotedIncoming(quoted)
        }
        // A mail reply without its quote below the caret (Apple Mail) could only find its thread by
        // the subject, which whoever sent the mail chose; it could name another thread. No answer.
        guard !isMail else {
            Self.trace("mail_without_quote", [:])
            return nil
        }
        guard let scope = ConversationScopeResolver.scope(
            bundleIdentifier: context.bundleIdentifier, conversationTitle: context.windowTitle, sourcesByBundle: sourcesByBundle()
        ), let engine = engine() else {
            Self.trace("no_scope", ["title": context.windowTitle ?? ""])
            return nil
        }
        for source in scope.sources where Self.chatSources.contains(source) {
            if Date().timeIntervalSince(lastSync[source] ?? .distantPast) > Self.syncInterval {
                lastSync[source] = Date()
                await historySync.sync(source)
            }
        }
        // Freshly synced, so a second conversation with the same name is found too: ambiguous.
        let found = engine.findConversations(title: scope.title, sources: scope.sources)
        guard found.count == 1, let conversation = found.first else {
            Self.trace("title_matches", [
                "title": scope.title, "matches": "\(found.count)", "sources": scope.sources.joined(separator: ",")
            ])
            return nil
        }
        let latest = await Task.detached(priority: .userInitiated) {
            engine.latestMessages(
                source: conversation.source, conversationID: conversation.conversationId, limit: Self.maximumIncomingRun + 1
            )
        }.value
        let run = Self.incomingRun(latest, conversation: conversation)
        if run == nil {
            Self.trace("newest_is_own", ["messages": "\(latest.count)", "newest_from_me": "\(latest.first?.isFromMe ?? false)"])
        }
        return run
    }

    /// The message quoted below the caret, as data: what is being asked and by whom. It never
    /// names a conversation (`conversation` is nil): the quote is written by its sender, so nothing
    /// in it may choose which remembered thread an answer treats as its own. Every fact such an
    /// answer uses comes from the user's opted-in answer sources (each marked as another
    /// conversation's on the card) or from busy/free times.
    nonisolated static func quotedIncoming(_ quoted: QuotedReplyParser.QuotedMessage) -> IncomingMessage {
        IncomingMessage(text: quoted.body, sender: quoted.sender, conversation: nil, recordIDs: [],
                        key: mailKey(quoted, subject: quoted.subject))
    }

    /// Why no incoming message was found, at debug level: titles name private conversations.
    private nonisolated static func trace(_ reason: String, _ fields: [String: String]) {
        var metadata: Logger.Metadata = ["category": "answers", "lookup": .string(reason)]
        for (key, value) in fields { metadata[key] = .string(value) }
        CotabbyLogger.app.debug("Answer incoming lookup", metadata: metadata)
    }

    /// The incoming messages at the end of a conversation (newest first in `latest`), or nil when
    /// the newest message is the user's own.
    nonisolated static func incomingRun(_ latest: [MemoryStore.StoredMessage], conversation: MemoryConversation) -> IncomingMessage? {
        guard let newest = latest.first, !newest.isFromMe else { return nil }
        let run = latest.prefix { !$0.isFromMe }.prefix(maximumIncomingRun)
        // Messages of one burst only: older than an hour before the newest is a different exchange.
        let burst = run.filter { newest.timestamp - $0.timestamp < 3600 }
        let recordIDs = Set(burst.map(\.recordID))
        return IncomingMessage(
            text: burst.reversed().map(\.text).joined(separator: "\n"),
            sender: newest.sender.isEmpty ? nil : newest.sender,
            conversation: conversation,
            recordIDs: recordIDs,
            key: chatKey(conversation: conversation, recordIDs: recordIDs)
        )
    }
}
