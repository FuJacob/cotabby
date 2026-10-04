import AppKit
import Combine
import CoreGraphics
import Foundation
import Logging

/// Runs augmented translation in the apps the user chose:
///
/// - **Incoming:** every 2 seconds (and shortly after scrolling) it captures the frontmost chat
///   window, reads its text, groups it into messages (`MessageBlockGrouper`), translates those not in
///   the reading language (`TranslationService`), and draws each translation under its message.
/// - **Reply:** when the user types a reply in their reading language in a chat whose language is
///   known, it shows the reply translated into that language under the field and installs a
///   shortcut that replaces the draft with it. It never sends anything.
///
/// Ownership: built once by `CotabbyAppEnvironment`, started and stopped by `AppDelegate`. It reads
/// the focus snapshot but never changes autocomplete state. Nothing it reads or translates is
/// stored: captures are dropped after OCR, translations live in an in-memory cache.
@MainActor
final class TranslationCoordinator {
    private let preferences: TranslationPreferencesStore
    private let service: TranslationService
    private let capture: WindowScreenshotService
    private let overlay: TranslationOverlayController
    private let focusModel: FocusTrackingModel
    private let inserter: SuggestionInserter
    private let hotkey: TranslationHotkeyTap
    /// Cotabby's own gates for an app: globally on, not paused, app not disabled, not Low Power Mode.
    private let isAllowed: @MainActor (String) -> Bool

    private var conversations = ConversationLanguageTracker()
    private var timer: Timer?
    private var scrollMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var incomingTask: Task<Void, Never>?
    private var lastCaptureSignature: (windowID: CGWindowID, frame: CGRect, hash: Int)?
    private var replyTask: Task<Void, Never>?
    private var offeredReply: (draft: String, translation: String)?
    /// The draft currently being translated. Focus updates arrive every ~50 ms; without this, each
    /// one would cancel the pending translation of a draft that has not changed.
    private var pendingReplyDraft: String?

    /// Most blocks translated per capture; the local model (Macedonian) is limited further because
    /// each translation takes about a second.
    private static let maximumBlocks = 30
    private static let maximumLocalModelBlocks = 5
    private static let replyDebounceNanoseconds: UInt64 = 700_000_000

    init(
        preferences: TranslationPreferencesStore,
        service: TranslationService,
        capture: WindowScreenshotService,
        overlay: TranslationOverlayController,
        focusModel: FocusTrackingModel,
        inserter: SuggestionInserter,
        hotkey: TranslationHotkeyTap,
        isAllowed: @escaping @MainActor (String) -> Bool
    ) {
        self.preferences = preferences
        self.service = service
        self.capture = capture
        self.overlay = overlay
        self.focusModel = focusModel
        self.inserter = inserter
        self.hotkey = hotkey
        self.isAllowed = isAllowed
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleIncomingPass() }
        }
        // Scrolling moves every message; hide stale labels at once and re-read once it settles.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.overlay.hideIncoming()
                self.lastCaptureSignature = nil
            }
        }
        focusModel.$snapshot
            .sink { [weak self] snapshot in self?.observeReply(snapshot) }
            .store(in: &cancellables)
        preferences.$preferences
            .map(\.isEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, !enabled else { return }
                self.overlay.hideAll()
                self.hotkey.remove()
                self.service.clearCache()
                self.conversations.removeAll()
            }
            .store(in: &cancellables)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        cancellables.removeAll()
        incomingTask?.cancel()
        replyTask?.cancel()
        hotkey.remove()
        overlay.hideAll()
    }

    // MARK: - Incoming

    private func scheduleIncomingPass() {
        guard incomingTask == nil else { return }
        incomingTask = Task { [weak self] in
            await self?.runIncomingPass()
            self?.incomingTask = nil
        }
    }

    private func runIncomingPass() async {
        let prefs = preferences.preferences
        guard prefs.isEnabled, prefs.translatesIncoming,
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier,
              preferences.isActive(forBundleIdentifier: bundleIdentifier),
              isAllowed(bundleIdentifier),
              CGPreflightScreenCaptureAccess()
        else {
            overlay.hideIncoming()
            lastCaptureSignature = nil
            return
        }

        do {
            let window = try await capture.captureActiveWindow(processIdentifier: app.processIdentifier)
            let hash = Self.sampleHash(window.image)
            if let last = lastCaptureSignature, last.windowID == window.windowID, last.frame == window.windowFrame,
               last.hash == hash {
                return
            }
            overlay.hideIncoming()

            let extractor = ScreenTextExtractor(
                maxImageDimension: 2400, maxRecognizedCharacters: 20_000,
                recognitionLanguages: Self.recognitionLanguages(reading: prefs.readingLanguage)
            )
            let text = try await extractor.extractText(from: window.image)
            let lines = text.lines.compactMap { line -> MessageBlockGrouper.Line? in
                guard let box = line.boundingBox else { return nil }
                return MessageBlockGrouper.Line(text: line.text, confidence: line.confidence, boundingBox: box)
            }
            let blocks = MessageBlockGrouper.blocks(
                from: lines, windowFrame: window.windowFrame, composeFrame: composeFrame(forPID: app.processIdentifier)
            )
            let labels = await translate(blocks, readingLanguage: prefs.readingLanguage,
                                         conversationKey: ConversationLanguageTracker.key(
                                             bundleIdentifier: bundleIdentifier, windowTitle: window.windowTitle))

            // The user may have switched apps or chats while this ran; never draw over the wrong window.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            lastCaptureSignature = (window.windowID, window.windowFrame, hash)
            overlay.showIncoming(labels, windowFrame: window.windowFrame)
        } catch {
            overlay.hideIncoming()
        }
    }

    /// Translates the most recent messages first (lowest on screen) and records the language of the
    /// newest one as the conversation's language.
    private func translate(_ blocks: [MessageBlock], readingLanguage: String, conversationKey: String) async -> [TranslationLabel] {
        var labels: [TranslationLabel] = []
        var localModelBudget = Self.maximumLocalModelBlocks
        var recordedConversation = false
        for (index, block) in blocks.reversed().prefix(Self.maximumBlocks).enumerated() {
            if Task.isCancelled { break }
            guard let detection = TranslationLanguagePolicy.needsTranslation(block.text, readingLanguage: readingLanguage)
            else { continue }
            if !recordedConversation {
                conversations.record(language: detection.language, for: conversationKey)
                recordedConversation = true
            }
            let availability = await service.availability(from: detection.language, to: readingLanguage)
            if availability == .localModel {
                guard localModelBudget > 0 else { continue }
                localModelBudget -= 1
            } else if availability != .ready {
                continue
            }
            guard let result = try? await service.translate(block.text, from: detection.language, to: readingLanguage),
                  result.translatedText.caseInsensitiveCompare(block.text) != .orderedSame
            else { continue }
            labels.append(TranslationLabel(id: index, text: result.translatedText, messageFrame: block.frame))
        }
        return labels
    }

    /// The reply field's frame in the same app, in global top-left points, so its text (the draft)
    /// and the chat list beside it are not read as messages.
    private func composeFrame(forPID pid: pid_t) -> CGRect? {
        guard let input = focusModel.snapshot.context, input.processIdentifier == pid,
              let frame = input.elementFrameRect ?? input.inputFrameRect else { return nil }
        return ScreenSpace.globalRect(fromCocoa: frame)
    }

    /// Vision hints: the reading language plus the scripts the user's chats are likely in. Vision has
    /// no Macedonian model; Russian and Ukrainian cover its Cyrillic letters best.
    private static func recognitionLanguages(reading: String) -> [String] {
        var languages = ["en-US", "tr-TR", "ru-RU", "uk-UA", "de-DE", "fr-FR", "es-ES", "it-IT", "nl-NL"]
        if let match = languages.firstIndex(where: { TranslationLanguagePolicy.sameLanguage($0, reading) }) {
            languages.insert(languages.remove(at: match), at: 0)
        }
        return languages
    }

    /// A cheap fingerprint of the captured pixels, so an unchanged chat is not re-read every 2 s.
    private static func sampleHash(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let length = CFDataGetLength(data)
        var hasher = Hasher()
        hasher.combine(image.width)
        hasher.combine(image.height)
        var offset = 0
        while offset < length {
            hasher.combine(bytes[offset])
            offset += 997
        }
        return hasher.finalize()
    }

    // MARK: - Reply

    private func observeReply(_ snapshot: FocusSnapshot) {
        let prefs = preferences.preferences
        guard prefs.isEnabled, prefs.offersReplyTranslation,
              case .supported = snapshot.capability,
              let input = snapshot.context, !input.isSecure,
              preferences.isActive(forBundleIdentifier: input.bundleIdentifier),
              isAllowed(input.bundleIdentifier),
              let conversationLanguage = conversations.language(
                  for: ConversationLanguageTracker.key(bundleIdentifier: input.bundleIdentifier, windowTitle: input.windowTitle)),
              !TranslationLanguagePolicy.sameLanguage(conversationLanguage, prefs.readingLanguage)
        else {
            withdrawReplyOffer()
            return
        }

        let draft = (input.precedingText + input.trailingText).trimmingCharacters(in: .whitespacesAndNewlines)
        if offeredReply?.draft == draft || pendingReplyDraft == draft { return }
        withdrawReplyOffer()
        guard draft.split(whereSeparator: \.isWhitespace).count >= 2,
              TranslationLanguagePolicy.isWritten(in: prefs.readingLanguage, draft)
        else { return }

        let fieldFrame = input.elementFrameRect ?? input.inputFrameRect ?? input.caretRect
        pendingReplyDraft = draft
        replyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.replyDebounceNanoseconds)
            guard let self, !Task.isCancelled else { return }
            let result = try? await self.service.translate(draft, from: prefs.readingLanguage, to: conversationLanguage)
            guard !Task.isCancelled, self.pendingReplyDraft == draft else { return }
            self.pendingReplyDraft = nil
            guard let result else { return }
            self.offerReply(draft: draft, translation: result.translatedText, language: conversationLanguage, fieldFrame: fieldFrame)
        }
    }

    private func offerReply(draft: String, translation: String, language: String, fieldFrame: CGRect) {
        let prefs = preferences.preferences
        offeredReply = (draft, translation)
        overlay.showReply(
            translation: translation,
            languageName: Locale.current.localizedString(forLanguageCode: language) ?? language,
            shortcutLabel: prefs.replaceKeyLabel,
            below: fieldFrame
        )
        hotkey.install(keyCode: prefs.replaceKeyCode, modifiers: prefs.replaceKeyModifiers) { [weak self] in
            self?.replaceDraft()
        }
    }

    /// Replaces the draft only if the field still holds exactly the text that was translated.
    private func replaceDraft() {
        guard let offeredReply, let input = focusModel.snapshot.context,
              (input.precedingText + input.trailingText).trimmingCharacters(in: .whitespacesAndNewlines) == offeredReply.draft
        else {
            withdrawReplyOffer()
            return
        }
        let translation = offeredReply.translation
        withdrawReplyOffer()
        if !inserter.replaceFieldText(with: translation) {
            CotabbyLogger.app.error("Reply translation could not replace the draft")
        }
    }

    private func withdrawReplyOffer() {
        replyTask?.cancel()
        replyTask = nil
        pendingReplyDraft = nil
        offeredReply = nil
        hotkey.remove()
        overlay.hideReply()
    }
}
