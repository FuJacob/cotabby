import ApplicationServices
import CoreGraphics
import Foundation
@testable import Cotabby

/// Shared constructors for tests that exercise Cotabby's pure autocomplete domain.
///
/// These helpers keep each test focused on the rule it is locking down. The production types are
/// intentionally explicit value objects, so building them inline in every test would bury the
/// meaningful input under repeated boilerplate.
enum CotabbyTestFixtures {
    static func focusedInputSnapshot(
        applicationName: String = "TestApp",
        bundleIdentifier: String = "com.example.TestApp",
        processIdentifier: Int32 = 123,
        elementIdentifier: String = "field",
        role: String = "AXTextField",
        subrole: String? = nil,
        caretRect: CGRect = CGRect(x: 10, y: 20, width: 2, height: 18),
        inputFrameRect: CGRect? = CGRect(x: 0, y: 0, width: 240, height: 32),
        caretSource: String = "test",
        caretQuality: CaretGeometryQuality = .exact,
        observedCharWidth: CGFloat? = nil,
        observedContentEdges: ObservedContentEdges? = nil,
        precedingText: String = "Hello",
        trailingText: String = "",
        selection: NSRange? = nil,
        isSecure: Bool = false,
        isIntegratedTerminal: Bool = false,
        isWebContentField: Bool = false,
        focusChangeSequence: UInt64 = 1,
        focusedURLString: String? = nil,
        windowTitle: String? = nil,
        fieldPlaceholder: String? = nil
    ) -> FocusedInputSnapshot {
        let resolvedSelection = selection
            ?? NSRange(location: (precedingText as NSString).length, length: 0)

        return FocusedInputSnapshot(
            applicationName: applicationName,
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier,
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretSource: caretSource,
            caretQuality: caretQuality,
            observedCharWidth: observedCharWidth,
            observedContentEdges: observedContentEdges,
            precedingText: precedingText,
            trailingText: trailingText,
            selection: resolvedSelection,
            isSecure: isSecure,
            isIntegratedTerminal: isIntegratedTerminal,
            isWebContentField: isWebContentField,
            focusChangeSequence: focusChangeSequence,
            focusedURLString: focusedURLString,
            windowTitle: windowTitle,
            fieldPlaceholder: fieldPlaceholder
        )
    }

    static func focusedInputContext(
        applicationName: String = "TestApp",
        bundleIdentifier: String = "com.example.TestApp",
        processIdentifier: Int32 = 123,
        elementIdentifier: String = "field",
        caretRect: CGRect = CGRect(x: 10, y: 20, width: 2, height: 18),
        inputFrameRect: CGRect? = CGRect(x: 0, y: 0, width: 240, height: 32),
        caretQuality: CaretGeometryQuality = .exact,
        observedCharWidth: CGFloat? = nil,
        observedContentEdges: ObservedContentEdges? = nil,
        precedingText: String = "Hello",
        trailingText: String = "",
        selection: NSRange? = nil,
        isSecure: Bool = false,
        isIntegratedTerminal: Bool = false,
        isWebContentField: Bool = false,
        focusChangeSequence: UInt64 = 1,
        focusedURLString: String? = nil,
        windowTitle: String? = nil,
        fieldPlaceholder: String? = nil,
        generation: UInt64 = 1
    ) -> FocusedInputContext {
        FocusedInputContext(
            snapshot: focusedInputSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                elementIdentifier: elementIdentifier,
                caretRect: caretRect,
                inputFrameRect: inputFrameRect,
                caretQuality: caretQuality,
                observedCharWidth: observedCharWidth,
                observedContentEdges: observedContentEdges,
                precedingText: precedingText,
                trailingText: trailingText,
                selection: selection,
                isSecure: isSecure,
                isIntegratedTerminal: isIntegratedTerminal,
                isWebContentField: isWebContentField,
                focusChangeSequence: focusChangeSequence,
                focusedURLString: focusedURLString,
                windowTitle: windowTitle,
                fieldPlaceholder: fieldPlaceholder
            ),
            generation: generation
        )
    }

    static func suggestionRequest(
        prefixText: String = "Hello",
        prompt: String = "PROMPT",
        precedingText: String? = nil,
        trailingText: String = "",
        generation: UInt64 = 1,
        maxPredictionTokens: Int = 8,
        completionLengthInstruction: String = "Return only the next few words.",
        userName: String? = nil,
        customRules: [String] = [],
        extendedContext: String? = nil,
        languageInstruction: String? = nil,
        clipboardContext: String? = nil,
        visualContextSummary: String? = nil,
        isMultiLineEnabled: Bool = false
    ) -> SuggestionRequest {
        let resolvedPrecedingText = precedingText ?? prefixText
        let context = focusedInputContext(
            precedingText: resolvedPrecedingText,
            trailingText: trailingText,
            generation: generation
        )

        return SuggestionRequest(
            context: context,
            prefixText: prefixText,
            prompt: prompt,
            generation: generation,
            maxPredictionTokens: maxPredictionTokens,
            temperature: 0.1,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            randomSeed: 42,
            maxSuffixCharacters: 192,
            completionLengthInstruction: completionLengthInstruction,
            userName: userName,
            customRules: customRules,
            extendedContext: extendedContext,
            languageInstruction: languageInstruction,
            clipboardContext: clipboardContext,
            visualContextSummary: visualContextSummary,
            isMultiLineEnabled: isMultiLineEnabled
        )
    }

    static func activeSession(
        fullText: String = " world again",
        consumedCharacterCount: Int = 0,
        basePrecedingText: String = "Hello",
        baseTrailingText: String = "",
        processIdentifier: Int32 = 123,
        latency: TimeInterval = 0.1
    ) -> ActiveSuggestionSession {
        ActiveSuggestionSession(
            baseContext: focusedInputContext(
                processIdentifier: processIdentifier,
                precedingText: basePrecedingText,
                trailingText: baseTrailingText
            ),
            fullText: fullText,
            consumedCharacterCount: consumedCharacterCount,
            latency: latency
        )
    }

    static func overlayGeometry(
        caretRect: CGRect = CGRect(x: 10, y: 20, width: 2, height: 18),
        inputFrameRect: CGRect? = CGRect(x: 0, y: 0, width: 240, height: 32),
        caretQuality: CaretGeometryQuality = .exact,
        isCaretAtEndOfLine: Bool = true,
        observedCharWidth: CGFloat? = nil,
        isRightToLeft: Bool = false
    ) -> SuggestionOverlayGeometry {
        SuggestionOverlayGeometry(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretQuality: caretQuality,
            isCaretAtEndOfLine: isCaretAtEndOfLine,
            observedCharWidth: observedCharWidth,
            isRightToLeft: isRightToLeft
        )
    }

    static func focusCapabilityCandidate(
        elementIdentifier: String = "candidate",
        role: String = "AXTextField",
        subrole: String? = nil,
        editableHintScore: Int = 0,
        hasStrongEditabilitySignal: Bool = true,
        isKnownReadOnlyRole: Bool = false,
        hasTextValue: Bool = true,
        hasSelectionRange: Bool = true,
        hasCaretBounds: Bool = true,
        isSecure: Bool = false
    ) -> FocusCapabilityCandidate {
        FocusCapabilityCandidate(
            elementIdentifier: elementIdentifier,
            role: role,
            subrole: subrole,
            editableHintScore: editableHintScore,
            hasStrongEditabilitySignal: hasStrongEditabilitySignal,
            isKnownReadOnlyRole: isKnownReadOnlyRole,
            hasTextValue: hasTextValue,
            hasSelectionRange: hasSelectionRange,
            hasCaretBounds: hasCaretBounds,
            isSecure: isSecure
        )
    }

    static func inputEvent(
        kind: CapturedInputEvent.Kind,
        keyCode: CGKeyCode = 0,
        characters: String = "",
        flags: CGEventFlags = []
    ) -> CapturedInputEvent {
        CapturedInputEvent(
            kind: kind,
            keyCode: keyCode,
            characters: characters,
            flags: flags
        )
    }

    static func settingsSnapshot(
        isGloballyEnabled: Bool = true,
        disabledAppBundleIdentifiers: Set<String> = [],
        suggestInIntegratedTerminals: Bool = false,
        selectedEngine: SuggestionEngineKind = .llamaOpenSource,
        selectedWordCountPreset: SuggestionWordCountPreset = .sevenToTwelve,
        isUsingCustomWordCountRange: Bool = false,
        customWordCountRange: SuggestionWordRange = SuggestionWordRange(lowWords: 5, highWords: 15),
        isClipboardContextEnabled: Bool = true,
        isSurfaceContextEnabled: Bool = true,
        userName: String = "",
        customRules: [String] = [],
        extendedContext: String = "",
        responseLanguages: [String] = [],
        debounceMilliseconds: Int = 50,
        focusPollIntervalMilliseconds: Int = 50,
        isMultiLineEnabled: Bool = false,
        autoAcceptTrailingPunctuation: Bool = true,
        addSpaceAfterAccept: Bool = false,
        streamSuggestionsWhileGenerating: Bool = false,
        isFastModeEnabled: Bool = false,
        mirrorPreference: MirrorPreference = .auto,
        acceptanceGranularity: AcceptanceGranularity = .word,
        suppressCompletionsOnTypo: Bool = false,
        offerTypoCorrections: Bool = false,
        enabledSpellingDictionaryCodes: [String] = SpellingDictionaryCatalog.defaultEnabledCodes,
        automaticallyFixTypos: Bool = false
    ) -> SuggestionSettingsSnapshot {
        SuggestionSettingsSnapshot(
            isGloballyEnabled: isGloballyEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            suggestInIntegratedTerminals: suggestInIntegratedTerminals,
            selectedEngine: selectedEngine,
            selectedWordCountPreset: selectedWordCountPreset,
            isUsingCustomWordCountRange: isUsingCustomWordCountRange,
            customWordCountRange: customWordCountRange,
            isClipboardContextEnabled: isClipboardContextEnabled,
            isSurfaceContextEnabled: isSurfaceContextEnabled,
            userName: userName,
            customRules: customRules,
            extendedContext: extendedContext,
            responseLanguages: responseLanguages,
            debounceMilliseconds: debounceMilliseconds,
            focusPollIntervalMilliseconds: focusPollIntervalMilliseconds,
            isMultiLineEnabled: isMultiLineEnabled,
            autoAcceptTrailingPunctuation: autoAcceptTrailingPunctuation,
            addSpaceAfterAccept: addSpaceAfterAccept,
            streamSuggestionsWhileGenerating: streamSuggestionsWhileGenerating,
            isFastModeEnabled: isFastModeEnabled,
            mirrorPreference: mirrorPreference,
            acceptanceGranularity: acceptanceGranularity,
            suppressCompletionsOnTypo: suppressCompletionsOnTypo,
            offerTypoCorrections: offerTypoCorrections,
            enabledSpellingDictionaryCodes: enabledSpellingDictionaryCodes,
            automaticallyFixTypos: automaticallyFixTypos
        )
    }
}
