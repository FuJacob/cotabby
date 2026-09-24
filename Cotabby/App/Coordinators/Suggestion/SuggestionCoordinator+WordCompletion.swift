import Foundation

/// Adapts pure word/presentation policies to the app's spell checker, local dictionary, and live
/// work identity. Keeping this at the orchestration boundary avoids giving pure rules access to
/// AppKit or user settings, and keeps the prediction lifecycle readable.
extension SuggestionCoordinator {
    /// Keeps prediction separate from its first visible offer. An uncertain word ending can be
    /// shown conservatively while its following words stay buffered. Validate their first word
    /// independently: the seam check that approved a name ending did not approve `teh` after it.
    func bufferedCompletionText(_ prediction: String, visibleText: String,
                                context: FocusedInputContext, isFinal: Bool) -> String {
        var buffered = visibleText
        if prediction.hasPrefix(visibleText), prediction.count > visibleText.count {
            let following = String(prediction.dropFirst(visibleText.count))
            if case .show = CompletionSeamGuard.presentation(
                precedingText: context.precedingText + visibleText + " ", completion: following,
                isFinal: isFinal, spellingAssessment: { self.completionSpellingAssessment(for: $0) }
            ) { buffered = prediction }
        }
        if !isFinal {
            let visibleCount = settingsSnapshot.showFollowingWords ? visibleText.count
                : SuggestionSessionReconciler.nextAcceptanceChunk(from: visibleText).count
            buffered = StreamedGhostTextPolicy.completedBufferedPrediction(buffered, visibleCharacterCount: visibleCount)
        }
        return buffered
    }

    func startCompletionSession(prediction: String, visibleText: String, context: FocusedInputContext,
                                latency: TimeInterval, isFinal: Bool, wordEndingOnly: Bool = false) -> ActiveSuggestionSession {
        let fullText = bufferedCompletionText(prediction, visibleText: visibleText, context: context, isFinal: isFinal)
        return interactionState.startSession(fullText: fullText,
            initialVisibleCharacterCount: wordEndingOnly || fullText != visibleText ? visibleText.count : nil,
            showFollowingWords: settingsSnapshot.showFollowingWords, liveContext: context, latency: latency)
    }

    func completionPresentation(
        text: String, context: FocusedInputContext, isFinal: Bool
    ) -> CompletionSeamGuard.PresentationDecision {
        let references = completionReferenceWords(context: context)
        let knownReferences = Set(references.map { $0.lowercased() })
        return CompletionSeamGuard.presentation(
            precedingText: context.precedingText, completion: text, isFinal: isFinal,
            spellingAssessment: { word in
                if knownReferences.contains(word.lowercased()) { return .known }
                if let cached = self.suggestionStreamingState.spellingAssessments[word] { return cached }
                let assessment = self.completionSpellingAssessment(for: word)
                self.suggestionStreamingState.spellingAssessments[word] = assessment
                return assessment
            }
        )
    }

    func completionReferenceWords(context: FocusedInputContext) -> Set<String> {
        WordCompletionFallback.referenceWords(precedingText: context.precedingText,
                                             trailingText: context.trailingText,
                                             glossary: settingsSnapshot.extendedContext)
    }

    /// A final unusable model result may fall back to a single exact-prefix word ending. This
    /// remains entirely local even for the endpoint backend and never invokes another generation.
    func localWordCompletion(context: FocusedInputContext) -> String? {
        guard context.trailingText.first?.isLetter != true,
              let prefix = CaretWordContext.unfinishedWord(in: context.precedingText) else { return nil }
        let languages = SpellingDictionaryCatalog.languages(for: settingsSnapshot.enabledSpellingDictionaryCodes)
        let language = spellingLanguageResolver.resolve(precedingText: context.precedingText,
                                                       currentWord: prefix, enabledLanguages: languages)
        let candidates = language.map { symSpellCorrector.completionCandidates(for: prefix, language: $0) } ?? []
        return WordCompletionFallback.suffix(for: prefix, references: completionReferenceWords(context: context),
                                             dictionaryCandidates: candidates)
    }

    func wasDismissed(_ text: String, context: FocusedInputContext) -> Bool {
        dismissalMemory.suppresses(identityKey: context.focusedInputIdentityKey,
                                  precedingText: context.precedingText, trailingText: context.trailingText,
                                  completion: text, at: ProcessInfo.processInfo.systemUptime)
    }

    func presentationDelay(context: FocusedInputContext) -> TimeInterval {
        typingCadence.remainingDelay(identityKey: context.focusedInputIdentityKey,
                                     precedingText: context.precedingText, at: ProcessInfo.processInfo.systemUptime)
    }

    /// Await inside the existing generation task so cancellation remains owned by the work
    /// controller. The caller must re-read focus and validate again after this suspension.
    func waitForTypingPause(workID: UInt64) async -> Bool {
        if let raw = focusModel.snapshot.context {
            let context = interactionState.materializeContext(from: raw)
            let delay = presentationDelay(context: context)
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return false }
            }
        }
        return !Task.isCancelled && workController.isCurrent(workID)
    }
}
