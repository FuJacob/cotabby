import AppKit
import XCTest
@testable import Cotabby

/// Tests for compact suggestion/session/presentation value models used directly by the coordinator,
/// menu, and overlay UI.
///
/// These are intentionally small, but they protect session slicing and presentation-state rules that
/// would otherwise regress quietly during coordinator or UI refactors.
final class SuggestionModelValueTests: XCTestCase {
    func test_languageCatalog_effectiveTokensPerWord_fallsBackToEnglishForMultiOrUnknown() {
        XCTAssertEqual(LanguageCatalog.effectiveTokensPerWord(for: []), LanguageCatalog.fallbackTokensPerWord)
        XCTAssertEqual(LanguageCatalog.effectiveTokensPerWord(for: ["German"]), 1.7)
        XCTAssertEqual(LanguageCatalog.effectiveTokensPerWord(for: ["english"]), 1.3)
        // Multi-language users get the safe English ratio so we don't have to guess which one wins.
        XCTAssertEqual(
            LanguageCatalog.effectiveTokensPerWord(for: ["German", "Spanish"]),
            LanguageCatalog.fallbackTokensPerWord
        )
        // Free-text languages we don't have factors for also fall back, instead of crashing or zero.
        XCTAssertEqual(
            LanguageCatalog.effectiveTokensPerWord(for: ["Klingon"]),
            LanguageCatalog.fallbackTokensPerWord
        )
    }

    // MARK: - ActiveSuggestionSession

    func test_activeSuggestionSession_clampsConsumedCountAndSlicesByCharacters() {
        let overConsumed = CotabbyTestFixtures.activeSession(fullText: "hello", consumedCharacterCount: 99)
        XCTAssertEqual(overConsumed.acceptedText, "hello")
        XCTAssertEqual(overConsumed.remainingText, "")
        XCTAssertTrue(overConsumed.isExhausted)

        // A negative count (e.g. a stale reconciliation delta) must clamp to the start, not index
        // before the string.
        let underConsumed = CotabbyTestFixtures.activeSession(fullText: "hello", consumedCharacterCount: -4)
        XCTAssertEqual(underConsumed.consumedCharacterCount, 0)
        XCTAssertEqual(underConsumed.remainingText, "hello")
    }

    func test_activeSuggestionSession_advancingByNegativeCountIsANoOp() {
        let session = CotabbyTestFixtures.activeSession(fullText: "hello", consumedCharacterCount: 2)

        XCTAssertEqual(session.advancing(by: -3).consumedCharacterCount, 2)
    }

    func test_activeSuggestionSession_whitespaceOnlyTailCountsAsExhausted() {
        // Ghost spaces are visually confusing, so a tail of only whitespace ends the session.
        let session = CotabbyTestFixtures.activeSession(fullText: "hello \n ", consumedCharacterCount: 5)

        XCTAssertTrue(session.isExhausted)
    }

    func test_activeSuggestionSession_clampsInitialVisibleBoundaryToTheText() {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: "abc",
            initialVisibleCharacterCount: 99,
            latency: 0
        )

        XCTAssertEqual(session.initialVisibleCharacterCount, 3)
        XCTAssertEqual(session.remainingText, "abc")
        XCTAssertFalse(session.hasBufferedContinuation)
    }

    func test_activeSuggestionSession_retainsFollowingWordsBehindAnInitialWordEnding() {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(precedingText: "Build a flux"),
            fullText: "beam for the device",
            initialVisibleCharacterCount: 4,
            latency: 0.05
        )

        XCTAssertEqual(session.remainingText, "beam")
        XCTAssertEqual(session.predictedRemainingText, "beam for the device")
        XCTAssertTrue(session.hasBufferedContinuation)

        let partlyTyped = session.advancing(by: 2)
        XCTAssertEqual(partlyTyped.remainingText, "am")
        XCTAssertTrue(partlyTyped.hasBufferedContinuation)

        let completedWord = partlyTyped.advancing(by: 2)
        XCTAssertEqual(completedWord.remainingText, " for the device")
        XCTAssertFalse(completedWord.isExhausted)
        XCTAssertFalse(completedWord.hasBufferedContinuation)
        XCTAssertEqual(completedWord.baseContext, session.baseContext)
    }

    func test_activeSuggestionSession_oneWordPresentationRollsThroughTheSamePrediction() {
        var session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: " hello world again",
            showFollowingWords: false,
            latency: 0.05
        )

        for expectedOffer in [" hello", " world", " again"] {
            XCTAssertEqual(session.remainingText, expectedOffer)
            XCTAssertFalse(session.isExhausted)
            session = session.advancing(by: expectedOffer.count)
        }
        XCTAssertTrue(session.isExhausted)
        XCTAssertEqual(session.remainingText, "")
    }

    func test_activeSuggestionSession_initialBoundaryCountsGraphemes() {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: "é👩🏽‍💻 next",
            initialVisibleCharacterCount: 2,
            latency: 0
        )

        XCTAssertEqual(session.remainingText, "é👩🏽‍💻")
        XCTAssertEqual(session.advancing(by: 1).remainingText, "👩🏽‍💻")
        XCTAssertEqual(session.withConsumedCharacters(2).remainingText, " next")
    }

    func test_activeSuggestionSession_extensionPreservesPresentationAndConsumedPosition() throws {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: "hello",
            initialVisibleCharacterCount: 5,
            showFollowingWords: false,
            consumedCharacterCount: 2,
            latency: 0.05
        )
        let extended = try XCTUnwrap(session.extendingPrediction(to: "hello world again"))

        XCTAssertEqual(extended.consumedCharacterCount, 2)
        XCTAssertEqual(extended.remainingText, "llo")
        XCTAssertEqual(extended.predictedRemainingText, "llo world again")
        XCTAssertEqual(extended.advancing(by: 3).remainingText, " world")
        XCTAssertEqual(extended.latency, session.latency)
        XCTAssertNil(session.extendingPrediction(to: "help instead"))
    }

    func test_activeSuggestionSession_unrestrictedExtensionImmediatelyOffersTheWholeTail() throws {
        let session = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(),
            fullText: "hello",
            latency: 0
        )

        XCTAssertEqual(try XCTUnwrap(session.extendingPrediction(to: "hello world")).remainingText, "hello world")
    }

    func test_activeSuggestionSession_correctionsNeverExtend() {
        // A correction commits as a whole-word replacement; streaming extra text onto it would turn
        // the replacement into a forward continuation.
        let correction = ActiveSuggestionSession(
            baseContext: CotabbyTestFixtures.focusedInputContext(precedingText: "teh"),
            fullText: "the",
            latency: 0,
            kind: .correction(typoWord: "teh")
        )

        XCTAssertNil(correction.extendingPrediction(to: "the end"))
        XCTAssertEqual(correction.advancing(by: 1).kind, .correction(typoWord: "teh"))
    }

    // MARK: - Focused context and presentation values

    func test_focusedInputContext_contentSignatureMirrorsSnapshotAndTagsSecureFields() {
        let context = CotabbyTestFixtures.focusedInputContext(
            elementIdentifier: "field-a",
            precedingText: "Hello",
            trailingText: " tail",
            focusChangeSequence: 7
        )
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "field-a",
            precedingText: "Hello",
            trailingText: " tail",
            focusChangeSequence: 7
        )

        XCTAssertEqual(context.contentSignature, "5::0::Hello:: tail::plain")
        // The context's fingerprint must stay interchangeable with the snapshot's so staleness
        // checks can compare across the debounce boundary.
        XCTAssertEqual(context.contentSignature, snapshot.contentSignature)

        let secure = CotabbyTestFixtures.focusedInputContext(isSecure: true)
        XCTAssertTrue(secure.contentSignature.hasSuffix("::secure"))
    }

    func test_suggestionKind_isCorrectionOnlyForCorrections() {
        XCTAssertTrue(SuggestionKind.correction(typoWord: "teh").isCorrection)
        XCTAssertFalse(SuggestionKind.continuation.isCorrection)
    }

    func test_overlayGeometry_withCaretRectReplacesOnlyTheCaretRect() {
        let style = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 13, colorHex: "336699")
        let edges = ObservedContentEdges(leftX: 4, topY: 30, isRunMeasured: true)
        let original = SuggestionOverlayGeometry(
            caretRect: CGRect(x: 10, y: 20, width: 2, height: 18),
            inputFrameRect: CGRect(x: 0, y: 0, width: 240, height: 32),
            caretQuality: .derived,
            bundleIdentifier: "com.example.host",
            isCaretAtEndOfLine: false,
            observedCharWidth: 7,
            isRightToLeft: true,
            focusChangeSequence: 9,
            focusedInputIdentityKey: 77,
            resolvedFieldStyle: style,
            observedContentEdges: edges
        )

        let advanced = original.withCaretRect(CGRect(x: 52, y: 20, width: 2, height: 18))

        XCTAssertEqual(advanced.caretRect, CGRect(x: 52, y: 20, width: 2, height: 18))
        XCTAssertEqual(advanced.inputFrameRect, original.inputFrameRect)
        XCTAssertEqual(advanced.caretQuality, .derived)
        XCTAssertEqual(advanced.bundleIdentifier, "com.example.host")
        XCTAssertFalse(advanced.isCaretAtEndOfLine)
        XCTAssertEqual(advanced.observedCharWidth, 7)
        XCTAssertTrue(advanced.isRightToLeft)
        XCTAssertEqual(advanced.focusChangeSequence, 9)
        XCTAssertEqual(advanced.focusedInputIdentityKey, 77)
        XCTAssertEqual(advanced.resolvedFieldStyle, style)
        XCTAssertEqual(advanced.observedContentEdges, edges)
    }

    func test_overlayState_visibleExposesRenderModeAndHiddenExposesNone() {
        let visible = OverlayState.visible(
            text: "hello",
            geometry: CotabbyTestFixtures.overlayGeometry(caretQuality: .derived),
            mode: .mirror(reason: .caretMidLine)
        )
        XCTAssertTrue(visible.isVisible)
        XCTAssertEqual(visible.visibleMode, .mirror(reason: .caretMidLine))

        let hidden = OverlayState.hidden(reason: "No suggestion buffered")
        XCTAssertFalse(hidden.isVisible)
        XCTAssertNil(hidden.visibleMode)
    }

    func test_suggestionClientError_errorDescriptionSurfacesTheUnderlyingMessage() {
        XCTAssertEqual(SuggestionClientError.unavailable("Engine offline").errorDescription, "Engine offline")
        XCTAssertEqual(
            SuggestionClientError.unsupportedLanguageOrLocale("Locale unsupported").errorDescription,
            "Locale unsupported"
        )
        XCTAssertEqual(SuggestionClientError.generationFailed("Decode failed").errorDescription, "Decode failed")
        XCTAssertEqual(SuggestionClientError.cancelled.errorDescription, "Generation was cancelled.")
    }
}

/// Runtime catalog, download-state, and generation-option values surfaced by onboarding, the menu,
/// and the llama engine.
final class RuntimeModelValueTests: XCTestCase {
    func test_modelDownloadStateProgressFractionIsClamped() {
        XCTAssertEqual(ModelDownloadState.downloading(progress: -0.5).progressFraction, 0)
        XCTAssertEqual(ModelDownloadState.downloading(progress: 0.42).progressFraction, 0.42)
        XCTAssertEqual(ModelDownloadState.downloading(progress: 1.5).progressFraction, 1)
        XCTAssertEqual(ModelDownloadState.paused(progress: 0.75).progressFraction, 0.75)
        XCTAssertNil(ModelDownloadState.downloading(progress: nil).progressFraction)
        XCTAssertNil(ModelDownloadState.paused(progress: nil).progressFraction)
        XCTAssertNil(ModelDownloadState.idle.progressFraction)
    }

    func test_modelDownloadStateStatusTextUsesRoundedPercent() {
        XCTAssertEqual(ModelDownloadState.idle.statusText, "Not installed")
        XCTAssertEqual(ModelDownloadState.downloading(progress: nil).statusText, "Downloading")
        XCTAssertEqual(ModelDownloadState.downloading(progress: 0.426).statusText, "Downloading 43%")
        XCTAssertEqual(
            ModelDownloadState.downloading(progress: 0.426, speedFormatted: "42.5 MB/s", etaFormatted: "1m 15s").statusText,
            "Downloading 43% (42.5 MB/s · ETA 1m 15s)"
        )
        XCTAssertEqual(ModelDownloadState.paused(progress: 0.50).statusText, "Paused (50%)")
        XCTAssertEqual(ModelDownloadState.paused(progress: nil).statusText, "Paused")
        XCTAssertEqual(ModelDownloadState.downloaded.statusText, "Installed")
        XCTAssertEqual(ModelDownloadState.failed("Network failed").statusText, "Network failed")
    }

    func test_runtimeModelCatalogMapsKnownNamesAndLeavesCustomNamesAlone() {
        let expectations: [(filename: String, displayName: String)] = [
            ("Qwen3.5-0.8B-Base.i1-Q6_K.gguf", "Cotabby Nano"),
            ("Qwen3.5-2B-Base.i1-Q4_K_M.gguf", "Cotabby Mini"),
            ("gemma-4-E2B.i1-Q6_K.gguf", "Cotabby Base"),
            ("gemma-4-E4B.i1-Q4_K_M.gguf", "Cotabby Pro"),
            // Retired models fall back to their raw filename like any unknown local GGUF. The 4B Qwen
            // base was dropped when the catalog moved to the nano/mini/base/pro four-tier lineup.
            ("Qwen3.5-4B-Base.i1-Q4_K_M.gguf", "Qwen3.5-4B-Base.i1-Q4_K_M.gguf"),
            ("Qwen3.5-0.8B-Q4_K_M.gguf", "Qwen3.5-0.8B-Q4_K_M.gguf"),
            ("gemma-3-1b-it-Q4_K_M.gguf", "gemma-3-1b-it-Q4_K_M.gguf"),
            ("custom-local-model.gguf", "custom-local-model.gguf")
        ]

        for expectation in expectations {
            XCTAssertEqual(
                RuntimeModelCatalog.displayName(for: expectation.filename),
                expectation.displayName,
                expectation.filename
            )
        }
    }

    func test_runtimeBootstrapState_summaryShowsDetailForEveryNonIdleState() {
        XCTAssertEqual(RuntimeBootstrapState.idle.summary, "Idle")
        XCTAssertEqual(RuntimeBootstrapState.starting("Locating runtime").summary, "Locating runtime")
        XCTAssertEqual(RuntimeBootstrapState.loading("Loading model").summary, "Loading model")
        XCTAssertEqual(RuntimeBootstrapState.ready("Cotabby Base ready").summary, "Cotabby Base ready")
        XCTAssertEqual(RuntimeBootstrapState.failed("Missing model file").summary, "Missing model file")
    }

    func test_runtimeBootstrapState_failureDetailIsNonNilOnlyWhenFailed() {
        XCTAssertEqual(RuntimeBootstrapState.failed("Missing model file").failureDetail, "Missing model file")
        XCTAssertNil(RuntimeBootstrapState.idle.failureDetail)
        XCTAssertNil(RuntimeBootstrapState.starting("Locating runtime").failureDetail)
        XCTAssertNil(RuntimeBootstrapState.loading("Loading model").failureDetail)
        XCTAssertNil(RuntimeBootstrapState.ready("Cotabby Base ready").failureDetail)
    }

    func test_runtimeModelOption_keepsRawFilenameAsIdentityButAliasesDisplayName() {
        let option = RuntimeModelOption(
            filename: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf",
            url: URL(fileURLWithPath: "/tmp/models/Qwen3.5-0.8B-Base.i1-Q6_K.gguf")
        )

        XCTAssertEqual(option.id, "Qwen3.5-0.8B-Base.i1-Q6_K.gguf")
        XCTAssertEqual(option.actualModelName, "Qwen3.5-0.8B-Base.i1-Q6_K.gguf")
        XCTAssertEqual(option.displayName, "Cotabby Nano")
    }

    func test_downloadableRuntimeModel_defaultsLeaveValidationMetadataEmpty() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/custom.gguf"))
        let model = DownloadableRuntimeModel(
            filename: "custom.gguf",
            displayName: "Custom",
            downloadURL: url,
            approximateSizeInGigabytes: 1.4
        )

        XCTAssertEqual(model.id, "https://example.com/custom.gguf")
        XCTAssertEqual(model.actualModelName, "custom.gguf")
        XCTAssertNil(model.expectedSizeBytes)
        XCTAssertNil(model.sha256)
        XCTAssertEqual(model.allKnownFilenames, ["custom.gguf"])
        XCTAssertEqual(model.approximateSizeLabel, "~1.4 GB")
    }

    func test_downloadableRuntimeModel_allKnownFilenamesListsPrimaryBeforeAlternates() throws {
        let model = DownloadableRuntimeModel(
            filename: "current.gguf",
            displayName: "Current",
            downloadURL: try XCTUnwrap(URL(string: "https://example.com/current.gguf")),
            approximateSizeInGigabytes: 0.5,
            alternateFilenames: ["legacy-a.gguf", "legacy-b.gguf"]
        )

        XCTAssertEqual(model.allKnownFilenames, ["current.gguf", "legacy-a.gguf", "legacy-b.gguf"])
    }

    func test_downloadableModelCatalog_entriesAreUniqueHuggingFaceGGUFDownloads() {
        let models = RuntimeModelCatalog.downloadableModels

        XCTAssertEqual(models.count, 4)
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        for model in models {
            XCTAssertTrue(model.filename.hasSuffix(".gguf"), "\(model.filename) should be a GGUF")
            XCTAssertEqual(model.downloadURL.host, "huggingface.co")
            XCTAssertTrue(model.downloadURL.absoluteString.hasSuffix("?download=true"))
            XCTAssertEqual(model.displayName, RuntimeModelCatalog.displayName(for: model.filename))
        }
    }

    func test_defaultRuntimeConfiguration_prefersExactlyTheDownloadableCatalog() {
        // The locator loads the first preferred file that exists. A preferred name missing from the
        // catalog could never be installed by onboarding, and a catalog model missing from the list
        // would lose its priority slot to alphabetical discovery.
        let preferred = LlamaRuntimeConfiguration.default.preferredModelNames
        let catalog = RuntimeModelCatalog.downloadableModels.map(\.filename)

        XCTAssertEqual(Set(preferred), Set(catalog))
        XCTAssertEqual(preferred.count, catalog.count, "Preferred names must not contain duplicates")
    }

    func test_llamaGenerationOptions_defaultsKeepMaskingAndSuppressionOff() {
        // Omitting the trailing parameters must reproduce the conservative production defaults:
        // no line masking, no forced word continuation, suppression disabled, two-token stop floor,
        // and the argmax end-of-generation stop left on.
        let options = LlamaGenerationOptions(
            maxPredictionTokens: 8,
            temperature: 0.1,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            seed: nil
        )

        XCTAssertNil(options.seed)
        XCTAssertFalse(options.singleLine)
        XCTAssertFalse(options.forceWordContinuation)
        XCTAssertEqual(options.confidenceFloor, -.infinity)
        XCTAssertEqual(options.sentenceStopMinimumTokens, 2)
        XCTAssertTrue(options.stopAtArgmaxEOG)
    }

    func test_llamaRuntimeError_errorDescriptionSurfacesTheUnderlyingMessage() {
        XCTAssertEqual(LlamaRuntimeError.unavailable("No model").errorDescription, "No model")
        XCTAssertEqual(LlamaRuntimeError.generationFailed("Decode failed").errorDescription, "Decode failed")
        XCTAssertEqual(LlamaRuntimeError.cancelled.errorDescription, "Runtime work was cancelled.")
    }
}

final class GhostTextColorPresetTests: XCTestCase {
    func test_matching_nilHexResolvesToAutomatic() {
        XCTAssertEqual(GhostTextColorPreset.matching(hex: nil), .automatic)
    }

    func test_matching_isCaseInsensitiveAndIgnoresWhitespace() {
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "  3b82f6 ").id, "blue")
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "EC4899").id, "pink")
    }

    func test_matching_unknownHexFallsBackToAutomatic() {
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "010203"), .automatic)
    }

    func test_allPresetHexesAreValidAndDecodable() {
        for preset in GhostTextColorPreset.all where preset.hex != nil {
            XCTAssertNotNil(
                SuggestionTextColorCodec.nsColor(fromHex: preset.hex),
                "Preset \(preset.id) has an undecodable hex"
            )
        }
    }
}
