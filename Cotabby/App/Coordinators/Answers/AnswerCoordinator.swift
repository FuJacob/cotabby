import AppKit
import Combine
import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Offers a drafted answer when the user opens an empty reply to a message that asks them something.
///
/// The flow, each step owned elsewhere so this file only orchestrates:
/// 1. A focused, non-secure reply field still waiting for its body, empty or holding only the
///    salutation (`ReplyFieldEmptiness.isAwaitingBody`), in a mail app or a chat app whose memory
///    source is on (`IncomingMessageResolver.answersIn`; never a browser page or any other field),
///    in an app Cotabby is on in (not paused, not disabled for the app, not off for Low Power
///    Mode), with Answer Questions on, memory running and an on-device model able to draft.
/// 2. The latest incoming message there (`IncomingMessageResolver`) and the question in it
///    (`QuestionDetector`).
/// 3. Facts from memory: the conversation being replied in (only when Cotabby identified it), plus
///    any conversation of the sources the user turned "Use for answers" on for (none by default),
///    never the question itself (`MemoryEngine.answerSearch`), and only when the best one is
///    relevant enough (`AnswerGroundingPolicy.shouldDraft`). A message that reads as instructions
///    to an assistant gets no answer, and remembered text that does never reaches the prompt
///    (`AnswerGroundingPolicy.looksLikeInstructions`). A question about the user's time
///    ("are you free Thursday?", `SchedulingQuestion`) also gets the calendar for the days it names,
///    read live from EventKit and turned into free/busy facts (`AvailabilityFacts`), whenever the
///    Calendar source is on (busy and free only, so this needs no "use for answers"); those facts
///    alone are enough to draft.
/// 4. A draft (`AnswerDraftEngine`, on this Mac only), kept only if every number and name in it is
///    in the facts or the question and it passes the other grounding guards (`AnswerGroundingPolicy`).
/// 5. A card under the caret line with the draft, what it answers, and every fact it was given,
///    each from another conversation marked (`AnswerAttribution`, `AnswerCardController`). A click
///    on it pastes the draft at the caret, where the user edits it like their own text. In an empty
///    reply Tab does the same; once a salutation is typed, ghost-text suggestions own Tab on that
///    line, so only the click inserts. Esc dismisses (`TemporaryKeyTap`, `AnswerCardKeyPolicy`); any
///    other key dismisses it and reaches the app as usual. Nothing is ever inserted without that
///    click or Tab, and nothing is ever sent: the draft is pasted for the user to edit.
///
/// Each question is drafted once (cached by message), a dismissed one is not offered again, and
/// every async step re-checks that the same field is still focused and still empty before acting.
/// Built by `CotabbyAppEnvironment`, started and stopped by `AppDelegate`.
@MainActor
final class AnswerCoordinator {
    /// The offer on screen, for which field and which message.
    private struct ShownOffer {
        let identity: FocusedInputIdentity
        /// The app the card was offered in; a paste goes nowhere else.
        let bundleIdentifier: String
        let offer: AnswerOffer
        let messageKey: String
    }

    /// What memory and the calendar found for one question.
    private struct Facts {
        /// Memory's facts, kept only when relevant enough to draft from.
        let hits: [MemorySearchResult.Hit]
        /// Free/busy facts for the days a scheduling question names; they come first in the prompt.
        let calendar: [AnswerPromptRenderer.Fact]
        let bestSimilarity: Double
        /// Memory's candidates before the relevance gate, for the log.
        let candidates: Int

        var isEmpty: Bool { hits.isEmpty && calendar.isEmpty }

        var forPrompt: [AnswerPromptRenderer.Fact] {
            let memoryFacts: [AnswerPromptRenderer.Fact] = hits.map { (hit: MemorySearchResult.Hit) in
                AnswerPromptRenderer.Fact(sender: hit.sender, isFromMe: hit.isFromMe, conversationTitle: hit.conversationTitle,
                                          timestamp: Date(timeIntervalSince1970: hit.timestamp), text: hit.text)
            }
            return calendar + memoryFacts
        }
    }

    /// How preparing one question ended: an offer, nothing to offer (cached, so the question is not
    /// drafted again), or a failure worth retrying on the next visit (not cached).
    private enum Outcome {
        case offer(AnswerOffer)
        case nothing
        case failed
    }

    private let focusModel: FocusTrackingModel
    private let memory: MemoryEngineController
    private let resolver: IncomingMessageResolver
    private let draftEngine: AnswerDraftEngine
    private let card: AnswerCardController
    private let keyTap: TemporaryKeyTap
    private let inserter: SuggestionInserter
    /// Whether Cotabby is on for an app: globally on, not paused, not disabled for the app.
    private let isAppAllowed: @MainActor (String) -> Bool

    private var cancellables: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private var pendingIdentity: FocusedInputIdentity?
    /// The field prepared last without an offer (nothing to answer, or a failure): not prepared
    /// again on every snapshot of the same field, only after it changes or the user leaves it.
    private var preparedIdentity: FocusedInputIdentity?
    /// When the focused element dropped while a draft or card was active (see `observe`).
    private var focusLostAt: Date?
    /// The app of the field being drafted for or offered in, to tell a focus flicker from leaving it.
    private var activeBundleIdentifier: String?
    private var shown: ShownOffer?
    /// Drafts per message key (nil: memory had no answer), and the messages the user dismissed.
    private var drafts: [String: AnswerOffer?] = [:]
    private var dismissed: Set<String> = []

    static let debounceNanoseconds: UInt64 = 400_000_000
    /// How long a focus flicker in the same app keeps a draft or card alive.
    static let focusFlickerGrace: TimeInterval = 1.5
    /// At most this many days of calendar facts, so memory's facts still fit in the prompt.
    static let maximumCalendarDays = 5

    init(
        focusModel: FocusTrackingModel, memory: MemoryEngineController, resolver: IncomingMessageResolver,
        draftEngine: AnswerDraftEngine, card: AnswerCardController, keyTap: TemporaryKeyTap,
        inserter: SuggestionInserter, isAppAllowed: @escaping @MainActor (String) -> Bool
    ) {
        self.focusModel = focusModel
        self.memory = memory
        self.resolver = resolver
        self.draftEngine = draftEngine
        self.card = card
        self.keyTap = keyTap
        self.inserter = inserter
        self.isAppAllowed = isAppAllowed
    }

    /// See `AnswerDraftEngine`: released through a nonisolated deinit.
    nonisolated deinit {}

    func start() {
        // `$snapshot` is the published focus stream; `[weak self]` keeps the subscription from
        // owning the coordinator.
        focusModel.$snapshot
            .sink { [weak self] snapshot in self?.observe(snapshot) }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        withdraw()
    }

    // MARK: - Observing

    private func observe(_ snapshot: FocusSnapshot) {
        // Outlook and other web-based composers drop their focused element for a moment while the
        // user is still in the reply ("No focused Accessibility element", then the same field back).
        // A draft takes seconds; ending it on that flicker meant it never finished. A snapshot with
        // no field in the same app is that flicker; another app, or the field itself turning
        // ineligible (the user started writing), still withdraws. The grace is short: focus resting
        // on a list in the same app is not a flicker, and the card's key tap must not outlive it.
        if snapshot.context == nil, task != nil || shown != nil, snapshot.bundleIdentifier == activeBundleIdentifier {
            if focusLostAt == nil {
                focusLostAt = Date()
                // Look again once the grace is over, even if no other snapshot arrives by then.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64((Self.focusFlickerGrace + 0.05) * 1_000_000_000))
                    guard let self else { return }
                    self.observe(self.focusModel.snapshot)
                }
            }
            if let lost = focusLostAt, Date().timeIntervalSince(lost) < Self.focusFlickerGrace { return }
        }
        focusLostAt = nil
        guard let input = eligibleInput(snapshot) else {
            if task != nil || shown != nil {
                CotabbyLogger.app.debug("Answer withdrawn", metadata: [
                    "category": "answers",
                    "reason": .string(snapshot.context == nil ? "focus_left_app" : "field_not_awaiting_body")
                ])
            }
            withdraw()
            preparedIdentity = nil
            return
        }
        // Same field, already offered, being prepared, or prepared without an offer: nothing to do.
        if shown?.identity == input.identity || pendingIdentity == input.identity || preparedIdentity == input.identity { return }
        withdraw()
        pendingIdentity = input.identity
        activeBundleIdentifier = input.bundleIdentifier
        // Debounced so tabbing through fields does not start a draft per field; `withdraw()`
        // cancels it when focus moves on, and every later step re-checks the field.
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard let self, !Task.isCancelled else { return }
            await self.prepare(for: input)
            guard !Task.isCancelled, self.pendingIdentity == input.identity else { return }
            self.pendingIdentity = nil
            self.task = nil
            if self.shown?.identity != input.identity { self.preparedIdentity = input.identity }
        }
    }

    private func eligibleInput(_ snapshot: FocusSnapshot) -> FocusedInputSnapshot? {
        guard let answers = memory.engine?.configuration.answers, answers.enabled,
              memory.state == .running, draftEngine.canDraft,
              case .supported = snapshot.capability,
              let input = snapshot.context, !input.isSecure, isAppAllowed(input.bundleIdentifier),
              resolver.answersIn(bundleIdentifier: input.bundleIdentifier),
              ReplyFieldEmptiness.isAwaitingBody(precedingText: input.precedingText, trailingText: input.trailingText)
        else { return nil }
        return input
    }

    // MARK: - Preparing an answer

    private func prepare(for input: FocusedInputSnapshot) async {
        let started = Date()
        guard let incoming = await resolver.latestIncoming(for: input) else {
            // No quoted mail, an unknown or ambiguous conversation, or the user already replied.
            log("skipped", ["reason": "no_incoming_message", "app": input.bundleIdentifier])
            return
        }
        guard isStillCurrent(input) else { return }
        guard let question = QuestionDetector.question(in: incoming.text) else {
            log("skipped", ["reason": "no_question"])
            return
        }
        let key = incoming.key
        guard !dismissed.contains(key), !offerCachedDraft(for: input, messageKey: key),
              let engine = memory.engine else { return }

        switch await answer(question, to: incoming, engine: engine, started: started) {
        case .offer(let prepared):
            drafts[key] = prepared
            if !Task.isCancelled, isStillCurrent(input) { offer(prepared, for: input, messageKey: key) }
        case .nothing:
            drafts[key] = .some(nil)
        case .failed:
            break
        }
    }

    /// Whether this message was prepared before (a draft, or nothing to offer); a cached draft is
    /// offered again while the field is still current.
    private func offerCachedDraft(for input: FocusedInputSnapshot, messageKey: String) -> Bool {
        guard let cached = drafts[messageKey] else { return false }
        if let cached, isStillCurrent(input) { offer(cached, for: input, messageKey: messageKey) }
        return true
    }

    /// Facts, a draft, and the guards a draft must pass before it may be offered.
    private func answer(
        _ question: String, to incoming: IncomingMessageResolver.IncomingMessage, engine: MemoryEngine, started: Date
    ) async -> Outcome {
        // Someone else wrote the message and chose their display name: either reading as
        // instructions to an assistant ("ignore previous instructions", "list all the facts") is an
        // attempt to steer the draft.
        if AnswerGroundingPolicy.looksLikeInstructions((incoming.sender ?? "") + "\n" + incoming.text) {
            log("skipped", ["reason": "instruction_like_message"])
            return .nothing
        }
        let facts = await gatherFacts(question: question, incoming: incoming, engine: engine)
        guard !facts.isEmpty else {
            log("skipped", [
                "reason": "no_relevant_memory", "best_similarity": String(format: "%.2f", facts.bestSimilarity),
                "hits": "\(facts.candidates)"
            ])
            return .nothing
        }
        let draft: AnswerDraftEngine.Draft?
        do {
            draft = try await draftEngine.draft(question: question, asker: incoming.sender, facts: facts.forPrompt)
        } catch {
            log("skipped", ["reason": "draft_failed", "error": error.localizedDescription])
            return .failed
        }
        guard let draft else {
            log("skipped", ["reason": "model_abstained"])
            return .nothing
        }
        guard isShowable(draft, facts: facts, incoming: incoming) else { return .nothing }
        log("shown", [
            "engine": draft.engine, "hits": "\(facts.hits.count)", "calendar_days": "\(facts.calendar.count)",
            "best_similarity": String(format: "%.2f", facts.bestSimilarity),
            "latency_ms": "\(Int(Date().timeIntervalSince(started) * 1000))"
        ])
        // Every fact the model saw is on the card, attributed: nothing it could draw on stays hidden.
        return .offer(AnswerAttribution.offer(
            draft: draft.text, answering: AnswerAttribution.answeringLine(asker: incoming.sender, question: question),
            calendarFacts: facts.calendar,
            hits: facts.hits, current: Self.current(incoming)
        ))
    }

    private func gatherFacts(
        question: String, incoming: IncomingMessageResolver.IncomingMessage, engine: MemoryEngine
    ) async -> Facts {
        let configuration = engine.configuration
        let answerSources = MemorySourceCatalog.all.map(\.id).filter {
            configuration.sources[$0]?.enabled == true && MemorySourceCatalog.isAnswerSource($0, settings: configuration.sources[$0])
        }
        let current = incoming.conversation.map { (source: $0.source, conversationID: $0.conversationId) }
        let excluded = incoming.recordIDs
        // The search embeds the question and scans the index: off the main actor.
        let result = await Task.detached(priority: .userInitiated) {
            engine.answerSearch(question: question, sources: answerSources, currentConversation: current, excludingRecordIDs: excluded)
        }.value
        // The quoted mail itself is not in `excluded` (no record id); never treat it as a fact. A
        // remembered message that reads as instructions never reaches the prompt either.
        let questionText = incoming.text.lowercased()
        let found = result.hits.filter {
            !questionText.contains($0.text.lowercased())
                && !AnswerGroundingPolicy.looksLikeInstructions([$0.sender, $0.conversationTitle, $0.text].joined(separator: "\n"))
        }
        let best = found.map(\.similarity).max() ?? 0
        let memoryIsRelevant = AnswerGroundingPolicy.shouldDraft(
            bestSimilarity: best, minimumSimilarity: configuration.answers.minimumConfidence,
            hasKeywordMatch: found.contains { $0.via != "vector" }
        ) && AnswerGroundingPolicy.factsMentionWhatTheQuestionNames(
            question: question, facts: found.map { "\($0.sender) \($0.conversationTitle) \($0.text)" }
        )
        let calendarFacts = await availabilityFacts(question: question, configuration: configuration)
        // Memory's facts only when relevant; the calendar's come first and leave room for them.
        let hits = memoryIsRelevant ? Array(found.prefix(AnswerPromptRenderer.maximumFacts - calendarFacts.count)) : []
        return Facts(hits: hits, calendar: calendarFacts, bestSimilarity: best, candidates: found.count)
    }

    /// Whether a draft may be offered: grounded in what the model was shown (each fact's sender,
    /// chat and text), and not reproducing another conversation's message. Logs why not.
    private func isShowable(
        _ draft: AnswerDraftEngine.Draft, facts: Facts, incoming: IncomingMessageResolver.IncomingMessage
    ) -> Bool {
        let shownFacts = AnswerPromptRenderer.factLines(facts.forPrompt)
        let unsupported = AnswerGroundingPolicy.unsupportedSpecifics(in: draft.text, facts: shownFacts, question: incoming.text)
        guard unsupported.isEmpty, AnswerGroundingPolicy.usesFacts(draft.text, facts: shownFacts, question: incoming.text),
              !AnswerGroundingPolicy.containsSecrets(draft.text) else {
            log("skipped", ["reason": "ungrounded", "unsupported": "\(unsupported.count)", "engine": draft.engine])
            // The words themselves only at debug level: they can be names from private mail.
            CotabbyLogger.app.debug("Answer ungrounded terms", metadata: [
                "category": "answers", "terms": .string(unsupported.joined(separator: ", "))
            ])
            return false
        }
        // The question comes from someone else; it must not be able to make the draft reproduce
        // another conversation's message wholesale.
        let current = Self.current(incoming)
        let copies = facts.hits.contains {
            AnswerAttribution.isOther($0, current: current) && AnswerGroundingPolicy.copiesPassage(draft.text, from: $0.text)
        }
        if copies {
            log("skipped", ["reason": "copies_other_conversation", "engine": draft.engine])
            return false
        }
        return true
    }

    /// Free/busy facts for the days a scheduling question names, from the calendar as it is now;
    /// empty when the question is not about the user's time or the calendar may not answer.
    private func availabilityFacts(question: String, configuration: MemoryConfiguration) async -> [AnswerPromptRenderer.Fact] {
        let now = Date()
        guard configuration.sources[CalendarHistoryReader.id]?.enabled == true, EventKitCalendar.isAuthorized,
              let days = SchedulingQuestion.days(in: question, now: now)?.prefix(Self.maximumCalendarDays),
              let first = days.first, let last = days.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return [] }
        // EventKit off the main actor: a store fetch can take a moment on a large calendar.
        let events = await Task.detached(priority: .userInitiated) { EventKitCalendar.events(from: first, to: end) }.value
        return AvailabilityFacts.facts(days: Array(days), events: events,
                                       language: AvailabilityFacts.language(of: question), now: now)
    }

    /// The conversation being answered, when the resolver identified it.
    private static func current(_ incoming: IncomingMessageResolver.IncomingMessage) -> AnswerAttribution.Conversation? {
        incoming.conversation.map { AnswerAttribution.Conversation(source: $0.source, conversationID: $0.conversationId) }
    }

    /// The same field is still focused and still empty.
    private func isStillCurrent(_ input: FocusedInputSnapshot) -> Bool {
        guard let now = focusModel.snapshot.context else { return false }
        return now.identity == input.identity
            && ReplyFieldEmptiness.isAwaitingBody(precedingText: now.precedingText, trailingText: now.trailingText)
    }

    // MARK: - The card

    private func offer(_ offer: AnswerOffer, for input: FocusedInputSnapshot, messageKey: String) {
        shown = ShownOffer(identity: input.identity, bundleIdentifier: input.bundleIdentifier, offer: offer, messageKey: messageKey)
        // Tab is the card's only in an empty reply: after a salutation the suggestion overlay may be
        // showing ghost text on the same line, and its Tab accept must keep working.
        let tabInserts = input.precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        card.show(
            offer, caret: input.caretRect, field: input.elementFrameRect ?? input.inputFrameRect,
            tabInserts: tabInserts, onInsert: { [weak self] in self?.insert() }
        )
        keyTap.install { [weak self] keyCode, flags in
            guard let self else { return .pass }
            switch AnswerCardKeyPolicy.action(keyCode: keyCode, flags: flags, tabInserts: tabInserts, cardShown: self.shown != nil) {
            case .insert:
                // Insert after the tap returns: the paste presses a menu item through Accessibility,
                // which must never run inside the tap callback.
                DispatchQueue.main.async { self.insert() }
                return .consume
            case .dismiss:
                DispatchQueue.main.async { self.dismiss() }
                return .consume
            case .passAndWithdraw:
                // Typing means the user writes their own reply.
                DispatchQueue.main.async { self.withdraw() }
                return .pass
            case .pass:
                return .pass
            }
        }
    }

    private func insert() {
        // The focus snapshot can lag behind an app switch; the frontmost app is asked directly, so a
        // paste never lands in an app other than the one the card was offered in.
        guard let shown, let input = focusModel.snapshot.context, input.identity == shown.identity,
              AnswerCardKeyPolicy.mayInsert(
                  cardBundleIdentifier: shown.bundleIdentifier, focusedBundleIdentifier: input.bundleIdentifier,
                  frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
              ),
              ReplyFieldEmptiness.isAwaitingBody(precedingText: input.precedingText, trailingText: input.trailingText) else {
            withdraw()
            return
        }
        // The user already greeted: paste the body, not a second salutation.
        let text = AnswerCardKeyPolicy.insertionText(draft: shown.offer.draft, precedingText: input.precedingText)
        let key = shown.messageKey
        withdraw()
        dismissed.insert(key)  // Answered: never offered again.
        // A paste, never a replace: in a mail reply the quoted original sits below the caret.
        if inserter.pasteAtCaret(text) {
            log("inserted", ["characters": "\(text.count)"])
        } else {
            CotabbyLogger.app.error("Answer could not be inserted")
        }
    }

    private func dismiss() {
        if let key = shown?.messageKey { dismissed.insert(key) }
        log("dismissed", [:])
        withdraw()
    }

    private func withdraw() {
        task?.cancel()
        task = nil
        pendingIdentity = nil
        shown = nil
        keyTap.remove()
        card.hide()
    }

    private func log(_ event: String, _ fields: [String: String]) {
        var metadata: Logger.Metadata = ["category": .string("answers"), "event": .string(event)]
        for (key, value) in fields { metadata[key] = .string(value) }
        CotabbyLogger.app.info("Answer \(event)", metadata: metadata)
    }
}
