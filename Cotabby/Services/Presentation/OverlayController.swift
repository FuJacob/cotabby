import AppKit
import Foundation
import Logging
import QuartzCore
import SwiftUI

/// File overview:
/// Owns the non-activating floating panel that renders ghost text near the caret. AppKit window
/// behavior stays isolated here so the coordinator only has to reason about overlay state.
///
/// Inline ghost text is rendered by `GhostTextPanelView` from a `GhostTextLayout` built in the
/// host's own font (`HostTypefaceResolver`) on the host's own baseline (`GhostBaselinePolicy`). The
/// controller keeps one `InlineSession` per shown suggestion: the full text, the anchor caret box it
/// was first shown at, and how much of it the host already contains. Acceptance and type-through
/// only advance that consumed count, so the glyphs that remain never move.
@MainActor
final class OverlayController: SuggestionOverlayControlling {
    var onStateChange: ((OverlayState) -> Void)?

    private let suggestionSettings: SuggestionSettingsModel

    /// Built from the live `mirrorPreference` setting at call time rather than cached, so the user's
    /// Settings/menu-bar toggle takes effect on the very next presentation.
    private var currentRenderModePolicy: CompletionRenderModePolicy {
        CompletionRenderModePolicy(userPreference: suggestionSettings.mirrorPreference)
    }

    /// What is presented and which requested presentation is held back from it. Every change to
    /// either goes through this value's transitions (see `OverlayPresentationLifecycle`).
    private var lifecycle = OverlayPresentationLifecycle<InlineSession>()

    var state: OverlayState { lifecycle.state }

    /// The text of a presentation `showSuggestion` accepted but has not applied yet (see
    /// `SuggestionOverlayControlling.heldPresentationText`). A hold returns before the presentation
    /// changes, so without this the coordinator could not tell its own in-flight present from a
    /// stale ghost, and rejected a rapid Tab that followed an accept.
    var heldPresentationText: String? { lifecycle.heldText }

    /// See `SuggestionOverlayControlling.truncatedDisplayText`. Read from the session the presented
    /// inline ghost was drawn from, so it changes exactly when the painted rows do (a present, an
    /// advance, a calibration re-layout). The lifecycle keeps a session only while an inline ghost
    /// is what is presented, so the card and a hidden overlay report nothing.
    var truncatedDisplayText: String? {
        guard let layout = lifecycle.inlineSession?.layout, layout.isTruncated else {
            return nil
        }
        return layout.remainingText
    }

    /// Tells the subscriber what is presented now. Called after every presentation transition,
    /// including one that presents the same thing again: what counts as a change is its to decide.
    private func publishState() {
        onStateChange?(state)
    }

    /// The inline renderer, reused across presentations; only its `content` changes per show.
    private var inlineView: GhostTextPanelView?
    /// Mirror mode keeps its SwiftUI hosting view; the two modes swap the panel's content view.
    private var mirrorHostingView: NSHostingView<MirrorOverlayView>?

    /// Everything needed to re-render the visible inline ghost after a consumed-prefix advance
    /// without touching Accessibility again.
    private struct InlineSession {
        let fullText: String
        var consumedUTF16: Int
        /// The host's caret box when `consumedUTF16` was zero; all rows derive from it.
        let anchorCaretRect: CGRect
        let geometry: SuggestionOverlayGeometry
        var fontResolution: GhostFontResolver.Resolution
        var baselineOffsetFromTop: CGFloat
        var baselineSource: BaselineSource
        var layout: GhostTextLayout
    }

    /// Where a session's baseline came from; the raw values are the `baseline_source` log field.
    private enum BaselineSource: String {
        /// The font-metrics rule (`GhostBaselinePolicy`).
        case policy
        /// Measured from a strip of the host's pixels (`HostBaselineCalibrator`).
        case calibrated
        /// Read from the capture that placed the caret (`PixelCaretLocator`).
        case pixel
    }

    /// Measures the caret from the host's pixels for paragraphs AX exposes only as one union run
    /// (see `PixelCaretLocator`). Owned here because the measurement is a presentation concern:
    /// it decides where the ghost is drawn and whether it can be drawn inline at all.
    private let pixelCaretLocator = PixelCaretLocator()
    /// Measures web hosts' painted baselines; nil where screen capture is unwanted (tests).
    private let baselineCalibrator: HostBaselineCalibrator?
    /// The face and size each field's ghost is drawn in, and what the field measured to get there.
    private let typefaces: HostTypefaceResolver

    /// `@MainActor` with stored properties, so without this Swift routes the deinit through the
    /// back-deployed `swift_task_deinitOnExecutorMainActorBackDeploy` shim, whose
    /// `TaskLocal::StopLookupScope` frees a pointer it never allocated on macOS 15 and aborts the
    /// process (CI's test host crashed releasing one in a test). The app owns one controller for
    /// its lifetime and tests release theirs on the main thread, so the panels and tasks it holds
    /// are still released there; nothing here needs the executor hop.
    nonisolated deinit {}

    init(
        suggestionSettings: SuggestionSettingsModel,
        baselineCalibrator: HostBaselineCalibrator? = nil,
        faceMemoryDefaults: UserDefaults? = nil
    ) {
        self.suggestionSettings = suggestionSettings
        self.baselineCalibrator = baselineCalibrator
        self.typefaces = HostTypefaceResolver(
            suggestionSettings: suggestionSettings,
            baselineCalibrator: baselineCalibrator,
            faceMemoryDefaults: faceMemoryDefaults
        )
        // Every fresh read of the host's caret is also a measurement of its text size (see
        // `HostTypefaceResolver.recordAdvanceCapture`); `[weak self]` because the locator and the
        // resolver are owned by this controller.
        pixelCaretLocator.onFreshCapture = { [weak self] request, measurement in
            self?.typefaces.recordAdvanceCapture(measurement, request: request)
        }
        typefaces.onHostFontRegistered = { [weak self] fontName in
            self?.redrawInlineAfterFontRegistration(fontName: fontName)
        }
    }

    private lazy var panel = NonActivatingPanel.makeDisplayOnly()

    /// Sizes and positions the overlay using the render mode the policy picks for this geometry.
    /// An inline pick that cannot be laid out honestly (the text needs a second row but the host
    /// exposed no line pitch, or it would paint over text after the caret) falls back to the card.
    func showSuggestion(_ text: String, geometry requestedGeometry: SuggestionOverlayGeometry) {
        guard !text.isEmpty else {
            hide(reason: "Overlay not shown because the suggestion was empty.")
            return
        }
        lifecycle.beginShow()
        // A caret the host has not yet moved for text it has already published (see
        // `CaretLagPolicy`): the next snapshot brings the real one, and a ghost drawn from this one
        // would sit over the typed text, sized from an empty line's box.
        if caretLagsTypedText(requestedGeometry) {
            CotabbyLogger.suggestion.debug(
                "Held a presentation whose caret lags the typed text",
                metadata: [
                    "stage": .string("caret-lag-hold"),
                    "caret_x": .stringConvertible(Double(requestedGeometry.caretRect.minX)),
                    "line_left": .stringConvertible(Double(requestedGeometry.hostTextMetrics?.lineRect?.minX ?? 0)),
                    "chars": .stringConvertible(requestedGeometry.lineTextBeforeCaret?.count ?? 0)
                ]
            )
            lifecycle.holdForCaretLag(text: text)
            return
        }
        // A caret inside a union-run paragraph is placed from the host's pixels (see
        // `pixelPlacedGeometry`); a presentation waiting for that capture returns here and runs again.
        guard let geometry = pixelPlacedGeometry(requestedGeometry, text: text) else { return }

        // Decide on the fade using the state *before* this presentation is applied below, so
        // the animation plays only on a genuine appearance, never on a reposition or streamed update.
        let fadesIn = SuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: suggestionSettings.fadeInSuggestions,
            overlayWasVisible: state.isVisible,
            reduceMotionEnabled: reduceMotionEnabled
        )

        let mode = currentRenderModePolicy.mode(for: geometry)

        CotabbyLogger.suggestion.debug(
            "Show suggestion",
            metadata: [
                "stage": .string("overlay-show"),
                "fades_in": .stringConvertible(fadesIn),
                "was_visible": .stringConvertible(state.isVisible),
                "mode": .string(mode.label),
                "panel_alpha_before": .stringConvertible(Double(panel.alphaValue)),
                "panel_visible_before": .stringConvertible(panel.isVisible)
            ]
        )
        // Start fully transparent so the panel's first composited frame is invisible. The else branch
        // resets the model value directly (off the animator) so a non-fading show can't resume a
        // stale mid-ramp animation semi-transparent.
        if fadesIn {
            panel.alphaValue = 0
        } else {
            panel.alphaValue = 1
        }

        switch mode {
        case .inline:
            switch showInline(text: text, geometry: geometry) {
            case .presented(let session):
                lifecycle.presentInline(session, text: text, geometry: geometry)
            case .declined(let reason):
                showMirror(text: text, geometry: geometry, reason: reason)
                lifecycle.presentMirror(text: text, geometry: geometry, reason: reason)
            }
        case .mirror(let reason):
            showMirror(text: text, geometry: geometry, reason: reason)
            lifecycle.presentMirror(text: text, geometry: geometry, reason: reason)
        }
        publishState()

        if fadesIn {
            fadeInPanel()
        }
    }

    /// The geometry to present `text` at, its caret placed from the host's pixels when AX cannot
    /// place it, or nil when the presentation must wait for a capture: `showSuggestion` then runs
    /// again with the answer.
    ///
    /// A caret inside a union-run paragraph is placed from the host's pixels, not from AX (which
    /// has no answer there) and not from a font-metric layout (which put the ghost on top of the
    /// host's own glyphs). The first presentation for a given paragraph text waits for the
    /// capture, typically tens of milliseconds; later ones reuse it. If the pixels yield nothing
    /// the presentation proceeds exactly as it would have without this service.
    ///
    /// A capture cannot see the run under Cotabby's own ghost (`panelCovers`). While the ghost
    /// is up, a re-anchor for text typed on since the run's capture carries that caret forward
    /// by the typed advance instead (`extrapolatedMeasurement`): the ghost's tail stays exactly
    /// where it was drawn. Anything else (the paragraph wrapped, an edit elsewhere) takes the
    /// ghost down for the read and puts it back where the pixels say. Re-anchoring to the
    /// Accessibility estimate instead put the ghost four lines up, or off screen, on every
    /// other keystroke of a typed-through suggestion (Obsidian, 2026-09-10).
    private func pixelPlacedGeometry(_ requestedGeometry: SuggestionOverlayGeometry, text: String) -> SuggestionOverlayGeometry? {
        guard let request = pixelCaretRequest(for: requestedGeometry) else { return requestedGeometry }
        let covered = panelCovers(request.runFrame)
        let status = pixelCaretLocator.status(of: request)
        let measured = status.measurement ?? (covered ? pixelCaretLocator.extrapolatedMeasurement(for: request) : nil)
        if let measured {
            return requestedGeometry.withPixelMeasuredCaret(
                measured.caretRect,
                lineRect: measured.lineRect,
                linePitch: measured.linePitch,
                baselineOffsetFromTop: measured.baselineOffsetFromTop,
                lineInkWidth: measured.lineInkWidth
            )
        }
        if case .failed = status { return requestedGeometry }
        if covered {
            panel.orderOut(nil)
            CotabbyLogger.suggestion.debug(
                "Ghost taken down for a pixel caret read",
                metadata: [
                    "stage": .string("pixel-caret-hold"),
                    "paragraph_chars": .stringConvertible(request.paragraphTextBeforeCaret.count)
                ]
            )
        }
        // Held before `locate`, not after it returns: a capture that fails or answers at once
        // calls back synchronously, and that nested `showSuggestion` must be free to retire the hold.
        let ticket = lifecycle.holdForPixelCapture(text: text, panelTakenDown: covered)
        pixelCaretLocator.locate(request) { [weak self] _ in
            // A show or hide since the hold retired it: the late read must not resurrect stale text.
            guard let self, self.lifecycle.isCurrent(ticket) else { return }
            self.showSuggestion(text, geometry: requestedGeometry)
        }
        return nil
    }

    /// Hides the floating panel and records why the overlay is no longer visible.
    func hide(reason: String) {
        CotabbyLogger.suggestion.debug("Overlay hidden", metadata: ["stage": .string("overlay-hide"), "reason": .string(reason)])
        panel.orderOut(nil)
        lifecycle.hide(reason: reason)
        publishState()
    }

    /// Mirrors the system Accessibility "Reduce Motion" preference, read live.
    private var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Ramps the panel from fully transparent to opaque over the user's configured fade duration.
    private func fadeInPanel() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = suggestionSettings.fadeInDurationSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    // MARK: - Inline ghost text

    private enum InlineOutcome {
        /// The ghost is drawn; the session is what redraws it.
        case presented(InlineSession)
        /// No honest inline layout exists for this text and geometry: the card must take over.
        case declined(CompletionRenderMode.MirrorReason)
    }

    /// Draws `text` anchored at the geometry's caret box as a fresh inline session. The caller
    /// records the outcome in `lifecycle`: a declined draw leaves the panel as it was.
    private func showInline(text: String, geometry: SuggestionOverlayGeometry) -> InlineOutcome {
        let renderer = geometry.hostRenderer
        let fontResolution = typefaces.resolveFont(for: geometry, renderer: renderer)
        let policyOffset = GhostBaselinePolicy.baselineOffsetFromTop(
            font: fontResolution.font,
            boxHeight: geometry.caretRect.height,
            renderer: renderer
        )
        let calibration = calibrationRequest(for: geometry, resolution: fontResolution, policyOffset: policyOffset)
        // The baseline read from the pixels that placed the caret outranks the calibrator's own
        // strip, which is cut around a box the frame arithmetic guessed.
        let pixelOffset = geometry.pixelBaselineOffset
        let cachedOffset = pixelOffset ?? calibration.flatMap { baselineCalibrator?.cachedOffset(for: $0.key) }
        let baselineOffsetFromTop = cachedOffset ?? policyOffset
        let anchorCaretRect = Self.refinedCaretRect(for: geometry, font: fontResolution)
        // Text follows the caret on its line: an inline ghost there could only sit on the host's own
        // characters, so the card under the caret shows the suggestion instead (the policy already
        // picks it under `auto`; this covers an explicit inline preference).
        guard geometry.isCaretAtEndOfLine else {
            logInlineDeclined(geometry: geometry, fontResolution: fontResolution, reason: .caretMidLine)
            return .declined(.caretMidLine)
        }
        guard let layout = makeLayout(
            fullText: text,
            consumedUTF16: 0,
            anchorCaretRect: anchorCaretRect,
            geometry: geometry,
            fontResolution: fontResolution,
            baselineOffsetFromTop: baselineOffsetFromTop
        ) else {
            logInlineDeclined(geometry: geometry, fontResolution: fontResolution, reason: .inlineLayoutUnavailable)
            return .declined(.inlineLayoutUnavailable)
        }
        let session = InlineSession(
            fullText: text,
            consumedUTF16: 0,
            anchorCaretRect: anchorCaretRect,
            geometry: geometry,
            fontResolution: fontResolution,
            baselineOffsetFromTop: baselineOffsetFromTop,
            baselineSource: pixelOffset != nil ? .pixel : (cachedOffset == nil ? .policy : .calibrated),
            layout: layout
        )
        renderInline(session)
        // Built after the render so the request knows where the panel now covers the host. Its
        // answer arrives asynchronously, by when the caller has recorded this session.
        if cachedOffset == nil || calibration?.matchTypeface == true,
           let calibration = calibrationRequest(for: geometry, resolution: fontResolution, policyOffset: policyOffset) {
            startCalibration(calibration, for: geometry)
        }
        return .presented(session)
    }

    /// The caret box to anchor the ghost at. Web hosts round caret boxes to whole pixels; when the
    /// host's exact face and the line's left edge are known, the caret x is recomputed from the
    /// text's own advance (see `GhostCaretRefinement`). Native hosts report exact carets already,
    /// and so does a caret read from the host's pixels: measured in Obsidian (2026-09-10), the
    /// typographic advance ran 1.5% longer than the host's own rendering of the same face and the
    /// refinement moved an exact pixel caret a point to the right.
    private static func refinedCaretRect(for geometry: SuggestionOverlayGeometry, font: GhostFontResolver.Resolution) -> CGRect {
        guard geometry.isWebContentField, !font.provenance.isFallbackFace, geometry.pixelBaselineOffset == nil,
              // A line box read through text markers (Chromium) places wrapped rows; this
              // refinement was measured against index-based line boxes (WebKit) only.
              geometry.hostTextMetrics?.lineRectIsFromTextMarkers != true,
              let lineLeft = geometry.hostTextMetrics?.lineRect?.minX,
              let paragraph = geometry.lineTextBeforeCaret,
              let refinedX = GhostCaretRefinement.caretX(
                  GhostCaretRefinement.Input(
                      lineLeft: lineLeft,
                      paragraphTextBeforeCaret: paragraph,
                      font: font.font,
                      reportedCaretX: geometry.caretRect.minX,
                      isRightToLeft: geometry.isRightToLeft
                  )
              )
        else {
            return geometry.caretRect
        }
        var rect = geometry.caretRect
        rect.origin.x = refinedX
        return rect
    }

    /// Fields taller than this are not one line; the single-line measurement would read the wrong
    /// ink. Chrome's address bar is 24pt; a multi-row composer starts around twice that.
    static let singleLineFieldMaximumHeight: CGFloat = 44
    /// The caret box reported for a single-line field, as a fraction of the field's height.
    static let singleLineCaretBoxFraction: CGFloat = 0.75
    /// Points above and below a one-line run that its pixel read includes: less than the four
    /// points between its line box and its neighbours', so their ink never reads as a line.
    static let oneLineRunVerticalPadding: CGFloat = 1
    /// Points past the typed text's estimated end that a one-line run's read reaches.
    static let oneLineRunReadMargin: CGFloat = 24

    /// The frame a one-line run is read in: its own line box, widened on the right to where its
    /// text now ends. The host reports the run as wide as its text was at its last layout, which
    /// trails the typing by a few characters, and a caret past that edge was refused as bad
    /// geometry. The width is the text before the caret in the ghost's face plus a margin, never
    /// past the field's own right edge (whatever the field paints beyond its text is not ink of
    /// this line).
    static func oneLineRunReadFrame(_ run: WrappedRunAnchor, font: NSFont, fieldRight: CGFloat?) -> CGRect {
        let textEnd = run.frame.minX + GhostFontResolver.width(of: run.paragraphTextBeforeCaret, font: font) + oneLineRunReadMargin
        var right = max(run.frame.maxX, textEnd)
        if let fieldRight, fieldRight > run.frame.maxX {
            right = min(right, fieldRight)
        }
        return CGRect(x: run.frame.minX, y: run.frame.minY, width: right - run.frame.minX, height: run.frame.height)
    }

    /// Whether a web field's caret still sits at its line's start behind text it already published
    /// (see `CaretLagPolicy`). Only where no pixel read will place the caret instead (a paragraph
    /// AX exposes as one run, `wrappedRun`, is measured from the host's own pixels), and only with the
    /// line's box to judge the leading edge by.
    private func caretLagsTypedText(_ geometry: SuggestionOverlayGeometry) -> Bool {
        guard geometry.isWebContentField, geometry.wrappedRun == nil,
              let line = geometry.hostTextMetrics?.lineRect, let text = geometry.lineTextBeforeCaret, !text.isEmpty
        else { return false }
        return CaretLagPolicy.caretLagsTypedText(
            caretX: geometry.caretRect.minX,
            line: line,
            textBeforeCaretOnLine: text,
            font: typefaces.resolveFont(for: geometry, renderer: .webEngine).font,
            isRightToLeft: geometry.isRightToLeft
        )
    }

    /// The pixel measurement this geometry needs, or nil when AX already placed the caret: a caret
    /// in a paragraph AX exposes as one union run, or one a single-line field could only estimate.
    /// At the end of its line the caret is where the line's ink ends; with text after it, it is
    /// found among the painted lines and places the card (`Request.caretIsMidLine`).
    private func pixelCaretRequest(for geometry: SuggestionOverlayGeometry) -> PixelCaretLocator.Request? {
        guard !geometry.isRightToLeft else { return nil }
        // A caret with text after it on its line gets the card, whose anchor a union run's
        // Accessibility answer cannot give either (Claude's composer: the field's right edge); its
        // pixels can, from the text before it (see `PixelCaretLocator.Request.caretIsMidLine`).
        let midLine = !geometry.isCaretAtEndOfLine
        let resolution = typefaces.resolveFont(for: geometry, renderer: geometry.hostRenderer)
        let font = resolution.font
        // The captures of a web field that reports no size measure its face's size (see
        // `HostTypefaceResolver.recordAdvanceCapture`, `HostTypefaceResolver.takesHostAdvance`).
        let recordsAdvance = !midLine && HostTypefaceResolver.takesHostAdvance(resolution, for: geometry)
        if let wrapped = geometry.wrappedRun {
            let trailingInkGap = PixelCaretLocator.trailingInkGap(after: wrapped.paragraphTextBeforeCaret, font: font)
                ?? PixelCaretLocator.inkToCaretGap
            // A one-line run is read as one line, in its own line box: see `oneLineRunReadFrame`.
            if wrapped.spansOneLine {
                return PixelCaretLocator.Request(
                    focusedInputIdentityKey: geometry.focusedInputIdentityKey,
                    runFrame: Self.oneLineRunReadFrame(wrapped, font: font, fieldRight: geometry.elementFrameRect?.maxX),
                    paragraphTextBeforeCaret: wrapped.paragraphTextBeforeCaret,
                    siblingLinePitch: nil,
                    siblingLineBoxHeight: nil,
                    spaceAdvance: GhostFontResolver.width(of: " ", font: font),
                    trailingInkGap: trailingInkGap,
                    singleLineCaretHeight: wrapped.frame.height,
                    verticalPadding: Self.oneLineRunVerticalPadding,
                    font: font,
                    recordsAdvance: recordsAdvance,
                    caretIsMidLine: midLine
                )
            }
            return PixelCaretLocator.Request(
                focusedInputIdentityKey: geometry.focusedInputIdentityKey,
                runFrame: wrapped.frame,
                paragraphTextBeforeCaret: wrapped.paragraphTextBeforeCaret,
                siblingLinePitch: geometry.hostTextMetrics?.linePitch,
                // A text-marker box is the text's glyph line, not the run's line box the pixel read expects.
                siblingLineBoxHeight: geometry.hostTextMetrics?.lineRectIsFromTextMarkers == true
                    ? nil : geometry.hostTextMetrics?.lineRect?.height,
                spaceAdvance: GhostFontResolver.width(of: " ", font: font),
                trailingInkGap: trailingInkGap,
                font: font,
                recordsAdvance: recordsAdvance,
                caretIsMidLine: midLine
            )
        }
        // A single-line field whose caret AX could only estimate (Chrome's address bar answers no
        // bounds query at all, measured 2026-09-10): the field frame is the line, and the caret is
        // where its ink ends. Estimated carets otherwise go to the card.
        guard !midLine, geometry.caretQuality == .estimated || geometry.caretQuality == .layoutEstimated,
              let frame = geometry.elementFrameRect, frame.height > 4, frame.height <= Self.singleLineFieldMaximumHeight,
              let text = geometry.lineTextBeforeCaret, !text.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            return nil
        }
        return PixelCaretLocator.Request(
            focusedInputIdentityKey: geometry.focusedInputIdentityKey,
            runFrame: frame,
            paragraphTextBeforeCaret: text,
            siblingLinePitch: nil,
            siblingLineBoxHeight: nil,
            spaceAdvance: GhostFontResolver.width(of: " ", font: font),
            trailingInkGap: PixelCaretLocator.trailingInkGap(after: text, font: font) ?? PixelCaretLocator.inkToCaretGap,
            // A fixed fraction of the field, not the estimate's own height: the estimate alternated
            // between 16 and 18pt for Chrome's 24pt address bar (measured 2026-09-10) and the ghost's
            // derived size flipped with it. The pixel match settles the size; this box only has to
            // be the same every time.
            singleLineCaretHeight: (frame.height * Self.singleLineCaretBoxFraction * 2).rounded() / 2,
            font: font,
            recordsAdvance: recordsAdvance,
            // An address-bar query is often shorter than a paragraph's line ever gets.
            advanceFitMinimumSpan: HostAdvanceFit.singleLineMinimumSpan
        )
    }

    /// Re-renders a visible inline suggestion once a host font finishes registering. A suggestion
    /// that arrived complete (no streaming, no further keystrokes) is drawn once in the stand-in
    /// and would otherwise stay that way until an unrelated later render. Guarded on the font
    /// actually resolving now, so a registration that reported success but left the name unusable
    /// cannot cause a pointless redraw loop.
    private func redrawInlineAfterFontRegistration(fontName: String) {
        guard case .inline(_, let text, let geometry) = lifecycle.presentation,
              geometry.resolvedFieldStyle?.fontName == fontName,
              GhostFontResolver.font(named: fontName, size: 12) != nil,
              case .presented(let session) = showInline(text: text, geometry: geometry)
        else { return }
        lifecycle.replaceInlineSession(session)
    }

    /// Starts measuring the host's baseline for the line the caret is on while the model is still
    /// generating, so the first ghost on that line already sits on the measured baseline.
    func prepareInlinePresentation(for context: FocusedInputContext) {
        guard baselineCalibrator != nil else { return }
        let geometry = SuggestionOverlayGeometry(
            caretRect: context.caretRect,
            inputFrameRect: context.inputFrameRect,
            caretQuality: context.caretQuality,
            // The host's bundled faces are looked up by bundle: without it this prewarm, which runs
            // first on every new line, matched without them and its verdict was kept for the line,
            // so Claude's Anthropic Sans never reached the match (2026-09-10: host_fonts 0 on every
            // match with enough text, 0.58 to 0.88 for the wrong faces).
            bundleIdentifier: context.bundleIdentifier,
            focusedURLString: context.focusedURLString,
            // Where the caret stands in its line decides how the pixel read below finds it: left at
            // its default, a caret moved back into a paragraph was read as its end (Obsidian,
            // 2026-09-11: 975.9 for a caret at 948.1, the line's ink end plus a space).
            isCaretAtEndOfLine: context.isCaretAtEndOfLine,
            observedCharWidth: context.observedCharWidth,
            isRightToLeft: false,
            focusChangeSequence: context.focusChangeSequence,
            focusedInputIdentityKey: context.focusedInputIdentityKey,
            resolvedFieldStyle: context.resolvedFieldStyle,
            hostTextMetrics: context.hostTextMetrics,
            isWebContentField: context.isWebContentField,
            hasTrailingContent: context.hasTrailingContent,
            isSingleLineField: context.isSingleLineField,
            elementFrameRect: context.elementFrameRect,
            lineTextBeforeCaret: GhostCaretRefinement.paragraphTextBeforeCaret(in: context.precedingText),
            wrappedRun: context.observedContentEdges?.wrappedRun
        )
        // The capture runs while the model generates, so the first ghost for this text already
        // knows its caret and nothing is held at presentation time.
        if let request = pixelCaretRequest(for: geometry), case .unknown = pixelCaretLocator.status(of: request),
           !panelCovers(request.runFrame) {
            pixelCaretLocator.locate(request) { _ in }
        }
        let renderer = geometry.hostRenderer
        let fontResolution = typefaces.resolveFont(for: geometry, renderer: renderer)
        let policyOffset = GhostBaselinePolicy.baselineOffsetFromTop(
            font: fontResolution.font,
            boxHeight: context.caretRect.height,
            renderer: renderer
        )
        guard let request = calibrationRequest(for: geometry, resolution: fontResolution, policyOffset: policyOffset) else {
            return
        }
        baselineCalibrator?.calibrate(request) { _ in }
    }

    private func calibrationRequest(
        for geometry: SuggestionOverlayGeometry,
        resolution: GhostFontResolver.Resolution,
        policyOffset: CGFloat
    ) -> HostBaselineCalibrator.Request? {
        guard baselineCalibrator != nil, Self.wantsBaselineCalibration(geometry, resolution: resolution) else { return nil }
        let font = resolution.font
        // The ghost panel, when up, is excluded from the capture and comes back black; the strip
        // must end before it. Its frame is the panel's current one: for a presentation this is
        // the ghost just rendered, for a prewarm the previous ghost or nothing.
        let occludedFrom: CGFloat? = panel.isVisible && panel.frame.intersects(geometry.caretRect.insetBy(dx: -maximumStripReach, dy: 0))
            ? panel.frame.minX - Self.occlusionMargin
            : nil
        let matchTypeface = !HostTypefaceResolver.hostNamesFace(geometry) && HostTypefaceResolver.acceptsPixelMatch(resolution.provenance)
        // A browser's bundle holds no page fonts; an Electron app's holds the faces its editor
        // is set in (Claude's composer: Anthropic Sans), which no installed candidate approximates.
        let isAppWebField = geometry.isWebContentField && !BrowserAppDetector.isBrowser(bundleIdentifier: geometry.bundleIdentifier)
        let hostFontNames = matchTypeface && isAppWebField
            ? typefaces.hostBundledFonts.candidateFontNames(forBundleIdentifier: geometry.bundleIdentifier)
            : []
        return HostBaselineCalibrator.Request(
            key: HostBaselineCalibrator.Key(
                focusedInputIdentityKey: geometry.focusedInputIdentityKey,
                lineTop: Int(geometry.caretRect.maxY.rounded()),
                caretHeight: Int(geometry.caretRect.height.rounded()),
                fontPointSize: Int(font.pointSize.rounded())
            ),
            caretRect: geometry.caretRect,
            contentLeft: geometry.hostTextMetrics?.lineRect?.minX ?? geometry.elementFrameRect?.minX,
            policyOffset: policyOffset,
            lineText: geometry.lineTextBeforeCaret,
            pointSize: font.pointSize,
            matchTypeface: matchTypeface,
            sizeIsReported: HostTypefaceResolver.sizeIsReported(resolution.provenance),
            sizeIsMeasured: HostTypefaceResolver.sizeIsMeasured(resolution.provenance),
            lineInkWidth: geometry.pixelLineInkWidth,
            occludedFrom: occludedFrom,
            hostFontNames: hostFontNames
        )
    }

    /// Whether Cotabby's own ghost panel lies over `frame` right now. A capture excludes the app's
    /// windows and an excluded region comes back black, so a pixel caret read under a visible
    /// ghost takes the panel's right edge for the line's ink (Obsidian, 2026-09-10: the caret
    /// measured 848, 1050 and 1244 on three consecutive keystrokes and the ghost teleported).
    /// No measurement is taken then: a presentation carries the run's last capture forward over
    /// the text typed since, or takes the ghost down for the read (`showSuggestion`).
    private func panelCovers(_ frame: CGRect) -> Bool {
        panel.isVisible && panel.frame.intersects(frame.insetBy(dx: -PixelCaretLocator.padding, dy: -PixelCaretLocator.padding))
    }

    /// How far left of the caret a calibration strip can reach; the panel matters only within it.
    private var maximumStripReach: CGFloat { HostBaselineCalibrator.maximumStripWidth + 4 }
    /// Points the excluded region was measured to extend past the panel's own frame.
    private static let occlusionMargin: CGFloat = 4

    /// Web hosts always: their boxes are rounded to pixels. Native hosts when the caret box is not
    /// the face's own TextKit line fragment, because then the policy has to guess where the extra
    /// line spacing went (Xcode's source editor puts it below the text; TextKit puts it above), and
    /// when the face itself is a stand-in (Chrome's address bar names no font), because then both
    /// the baseline and the face are guesses the pixels can replace.
    private static func wantsBaselineCalibration(
        _ geometry: SuggestionOverlayGeometry,
        resolution: GhostFontResolver.Resolution
    ) -> Bool {
        // An estimated caret is not a line: for a union-run paragraph it is the whole field, and a
        // strip cut from it measured whatever line happened to lie there (Obsidian, 2026-09-10:
        // eighteen typeface searches of 70-360ms on nothing, competing with the model). The pixel
        // caret upgrades the geometry to `.derived` before presentation; the calibration runs then.
        guard geometry.caretQuality != .estimated else { return false }
        if geometry.isWebContentField || resolution.provenance.isFallbackFace {
            return true
        }
        let defaultHeight = NSLayoutManager().defaultLineHeight(for: resolution.font)
        return abs(geometry.caretRect.height - defaultHeight) > 1
    }

    /// Measures the baseline for a ghost already on screen. When the answer differs from the policy
    /// value the visible rows move once, by at most one device pixel, onto the host's real baseline;
    /// every later present on this line starts there.
    private func startCalibration(_ request: HostBaselineCalibrator.Request, for geometry: SuggestionOverlayGeometry) {
        baselineCalibrator?.calibrate(request) { [weak self] calibration in
            guard let self, var session = self.lifecycle.inlineSession,
                  session.geometry.focusedInputIdentityKey == geometry.focusedInputIdentityKey,
                  session.anchorCaretRect.maxY == geometry.caretRect.maxY
            else {
                return
            }
            var changed = false
            if session.geometry.pixelBaselineOffset == nil, abs(session.baselineOffsetFromTop - calibration.baselineOffset) > 0.01 {
                session.baselineOffsetFromTop = calibration.baselineOffset
                session.baselineSource = .calibrated
                changed = true
            }
            // The face goes through the path a present takes (`HostTypefaceResolver.resolveFont`,
            // which reads the match the calibrator just recorded), so the ghost re-rendered here is
            // the one the next keystroke presents. Re-applying the fresh match to the session's own
            // face skipped the size the field's caret advance had measured: Claude's Code
            // composer, which reports no size, drew the match's raw 15.48 for a frame between 15.34
            // frames after each of two matches two seconds apart (2026-09-11).
            let rematched = self.typefaces.resolveFont(for: session.geometry, renderer: session.geometry.hostRenderer)
            if rematched.font != session.fontResolution.font {
                session.fontResolution = rematched
                changed = true
            }
            guard changed, let layout = self.makeLayout(for: session) else { return }
            session.layout = layout
            self.lifecycle.replaceInlineSession(session)
            self.renderInline(session)
        }
    }

    /// Advances the visible inline ghost past `insertedText` (typed through or accepted) by moving
    /// the consumed boundary inside the same session. No Accessibility geometry is read, so the
    /// rows that stay visible keep their exact pixels. Returns false when the held session cannot
    /// account for the change; the caller then re-anchors through a fresh present.
    func advanceInline(to remainingText: String, insertedText: String) -> Bool {
        // With the panel down for a capture there is nothing on screen to slide; the fresh present
        // this asks for retires the held one and reads the caret for the advanced text itself.
        guard !lifecycle.isPanelTakenDownForCapture, var session = lifecycle.inlineSession else {
            return false
        }
        let full = session.fullText as NSString
        let insertedLength = (insertedText as NSString).length
        let newConsumed = session.consumedUTF16 + insertedLength
        guard insertedLength > 0, newConsumed < full.length,
              full.substring(with: NSRange(location: session.consumedUTF16, length: insertedLength)) == insertedText,
              full.substring(from: newConsumed) == remainingText
        else {
            return false
        }
        session.consumedUTF16 = newConsumed
        guard let layout = makeLayout(for: session) else {
            return false
        }
        session.layout = layout
        renderInline(session)

        // The geometry the coordinator sees keeps its caret at the predicted insertion point so the
        // stability gate compares fresh AX carets against where the ghost actually is.
        let advancedCaret = predictedCaretRect(for: session)
        lifecycle.advanceInline(to: session, remainingText: remainingText, geometry: session.geometry.withCaretRect(advancedCaret))
        publishState()
        return true
    }

    /// Where the host's caret should be after the consumed prefix lands: the first visible row's pen.
    private func predictedCaretRect(for session: InlineSession) -> CGRect {
        guard let first = session.layout.rows.first(where: { !$0.text.isEmpty }) else {
            return session.anchorCaretRect
        }
        return CGRect(
            x: first.penX,
            y: first.baselineY + session.baselineOffsetFromTop - session.anchorCaretRect.height,
            width: session.anchorCaretRect.width,
            height: session.anchorCaretRect.height
        )
    }

    private func makeLayout(for session: InlineSession) -> GhostTextLayout? {
        makeLayout(
            fullText: session.fullText,
            consumedUTF16: session.consumedUTF16,
            anchorCaretRect: session.anchorCaretRect,
            geometry: session.geometry,
            fontResolution: session.fontResolution,
            baselineOffsetFromTop: session.baselineOffsetFromTop
        )
    }

    // swiftlint:disable function_parameter_count
    /// The rows for `fullText` past its consumed prefix, anchored at the caret box the session was
    /// first shown at. Takes the session's inputs rather than a session so the first layout exists
    /// before the session does: a session is only ever created with a layout that can be drawn.
    private func makeLayout(
        fullText: String,
        consumedUTF16: Int,
        anchorCaretRect: CGRect,
        geometry: SuggestionOverlayGeometry,
        fontResolution: GhostFontResolver.Resolution,
        baselineOffsetFromTop: CGFloat
    ) -> GhostTextLayout? {
        // swiftlint:enable function_parameter_count
        let acceptanceHintLabel = suggestionSettings.acceptanceHintLabel(
            forBundleIdentifier: geometry.bundleIdentifier
        )
        let keycapWidth = acceptanceHintLabel.map(GhostTextPanelView.keycapWidth(for:)) ?? 0
        // The user's bold/italic style is applied to the drawing face only. The plain host face
        // still measures what the host will render (the accepted prefix), so a styled ghost keeps
        // starting at the host's real caret after every accept.
        let hostFont = fontResolution.font
        let drawingFont = GhostFontStyler.styled(
            hostFont,
            bold: suggestionSettings.isGhostTextBold,
            italic: suggestionSettings.isGhostTextItalic
        )
        return GhostTextLayout.make(
            GhostTextLayout.Input(
                fullText: fullText,
                consumedUTF16: consumedUTF16,
                font: drawingFont,
                measuringFont: drawingFont == hostFont ? nil : hostFont,
                anchorTopLeft: CGPoint(x: anchorCaretRect.minX, y: anchorCaretRect.maxY),
                boxHeight: anchorCaretRect.height,
                baselineOffsetFromTop: baselineOffsetFromTop,
                linePitch: typefaces.linePitch(for: geometry, fontSize: hostFont.pointSize),
                wrapBand: wrapBand(for: geometry),
                isRightToLeft: geometry.isRightToLeft,
                // A second row would paint over the host's own following lines; with text below
                // the caret the ghost keeps to the caret row and reveals the rest as it is accepted.
                // A single-line field has no line below at all: its text scrolls sideways.
                allowsMultipleRows: !geometry.hasTrailingContent && !geometry.isSingleLineField,
                keycapWidth: keycapWidth
            )
        )
    }

    /// The horizontal band ghost rows may occupy (see `GhostWrapBandPolicy`).
    ///
    /// Code editors built on a hidden textarea (VS Code's Monaco) report an element only as wide
    /// as the current line's text, with the caret on its right edge, while the real text container
    /// is the editor view around it; for those the container frame is used instead.
    private func wrapBand(for geometry: SuggestionOverlayGeometry) -> ClosedRange<CGFloat>? {
        let isCodeEditor = AppSurfaceClassifier.classify(
            bundleIdentifier: geometry.bundleIdentifier,
            isIntegratedTerminal: false
        ) == .codeEditor
        return GhostWrapBandPolicy.band(
            GhostWrapBandPolicy.Input(
                caretRect: geometry.caretRect,
                elementFrame: isCodeEditor ? nil : geometry.elementFrameRect,
                inputFrame: geometry.inputFrameRect,
                lineLeft: geometry.hostTextMetrics?.lineRect?.minX,
                screenVisibleFrame: targetScreenVisibleFrame(for: geometry.caretRect)
            )
        )
    }

    private func renderInline(_ session: InlineSession) {
        let layout = session.layout
        let contentView: GhostTextPanelView
        if let existing = inlineView {
            contentView = existing
        } else {
            let fresh = GhostTextPanelView(frame: .zero)
            inlineView = fresh
            contentView = fresh
        }
        if panel.contentView !== contentView {
            panel.contentView = contentView
        }

        // AppKit rounds window frames to whole points (measured: a frame requested at 100.5 lands
        // at 100), so the panel is placed on whole points here and the view keeps the fractional
        // text offset inside. Snapping to half points instead shifted every ghost by 0.5pt whenever
        // the rounding went the other way.
        let padded = layout.contentBounds.insetBy(dx: -4, dy: -4)
        let frame = CGRect(
            x: floor(padded.minX),
            y: floor(padded.minY),
            width: ceil(padded.maxX) - floor(padded.minX) + 1,
            height: ceil(padded.maxY) - floor(padded.minY) + 1
        )
        // Last-resort guard: AppKit raises on a non-finite frame.
        guard AXHelper.rectHasFiniteComponents(frame), frame.width > 0, frame.height > 0 else {
            CotabbyLogger.suggestion.warning("Skipped inline overlay: computed a non-finite frame")
            return
        }

        let acceptanceHintLabel = suggestionSettings.acceptanceHintLabel(
            forBundleIdentifier: session.geometry.bundleIdentifier
        )
        contentView.content = GhostTextPanelView.Content(
            layout: layout,
            textColor: ghostTextColor(for: session.geometry),
            keycapLabel: acceptanceHintLabel,
            panelOrigin: frame.origin,
            isDarkAppearance: isDarkAppearance
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        logInlinePresentation(session, panelFrame: frame)
    }

    /// Priority: correction green, explicit user color, host field color, then an adaptive gray.
    private func ghostTextColor(for geometry: SuggestionOverlayGeometry) -> NSColor {
        let opacity = CGFloat(suggestionSettings.ghostTextOpacity)
        if geometry.isCorrection {
            return GhostTextPalette.correction(dark: isDarkAppearance).withAlphaComponent(opacity)
        }
        let base = SuggestionTextColorCodec.nsColor(fromHex: suggestionSettings.customSuggestionTextColorHex)
            ?? fieldGhostColor(from: geometry.resolvedFieldStyle)
            ?? GhostTextPalette.automaticText(dark: isDarkAppearance)
        return base.withAlphaComponent(opacity)
    }

    private var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: - Mirror card

    /// Mirror-mode rendering. Draws the suggestion inside a Cotabby-owned card anchored beneath the
    /// best available text line.
    private func showMirror(
        text: String,
        geometry: SuggestionOverlayGeometry,
        reason: CompletionRenderMode.MirrorReason
    ) {
        let acceptanceHintLabel = suggestionSettings.acceptanceHintLabel(
            forBundleIdentifier: geometry.bundleIdentifier
        )
        let visibleFrame = targetScreenVisibleFrame(for: geometry.caretRect)
        let layout = MirrorOverlayLayout.make(
            suggestion: text,
            geometry: geometry,
            visibleFrame: visibleFrame,
            showsAcceptanceHint: acceptanceHintLabel != nil,
            autoAcceptTrailingPunctuation: suggestionSettings.autoAcceptTrailingPunctuation,
            sizeMultiplier: typefaces.ghostSizeMultiplier,
            hostFontSize: typefaces.mirrorHostFontSize(for: geometry),
            isBold: suggestionSettings.isGhostTextBold,
            isItalic: suggestionSettings.isGhostTextItalic,
            reason: reason
        )
        let customGhostColor = SuggestionTextColorCodec.color(
            fromHex: suggestionSettings.customSuggestionTextColorHex
        )
        let rootView = MirrorOverlayView(
            layout: layout,
            customColor: customGhostColor,
            keycapLabel: acceptanceHintLabel,
            opacity: suggestionSettings.ghostTextOpacity,
            isCorrection: geometry.isCorrection
        )

        let contentView: NSHostingView<MirrorOverlayView>
        if let existing = mirrorHostingView {
            existing.rootView = rootView
            contentView = existing
        } else {
            let fresh = NSHostingView(rootView: rootView)
            mirrorHostingView = fresh
            contentView = fresh
        }

        if panel.contentView !== contentView {
            panel.contentView = contentView
        }

        let panelFrame = layout.panelFrame
        guard AXHelper.rectHasFiniteComponents(panelFrame) else {
            CotabbyLogger.suggestion.warning("Skipped mirror overlay: computed a non-finite frame")
            return
        }
        panel.setFrame(panelFrame, display: true)
        panel.orderFrontRegardless()
        logMirrorPresentation(geometry: geometry, reason: reason, panelFrame: panelFrame)
    }

    /// Maps the host field's foreground color to a ghost color, or nil to fall back to the default
    /// gray. Near-white / near-black extremes are untrustworthy (some browsers report the page
    /// background as the text color) and fall back, so ghost text never renders invisibly.
    private func fieldGhostColor(from style: ResolvedFieldStyle?) -> NSColor? {
        guard let hex = style?.colorHex,
              let nsColor = SuggestionTextColorCodec.nsColor(fromHex: hex)?.usingColorSpace(.sRGB)
        else {
            return nil
        }

        let luminance = 0.299 * nsColor.redComponent
            + 0.587 * nsColor.greenComponent
            + 0.114 * nsColor.blueComponent
        guard luminance > 0.06, luminance < 0.94 else {
            return nil
        }
        return nsColor
    }

    private func targetScreen(for caretRect: CGRect) -> NSScreen? {
        let midpoint = CGPoint(x: caretRect.midX, y: caretRect.midY)
        return NSScreen.screens.first { $0.frame.contains(midpoint) }
            ?? NSScreen.screens.first { $0.frame.intersects(caretRect) }
            ?? NSScreen.main
    }

    private func targetScreenVisibleFrame(for caretRect: CGRect) -> CGRect {
        targetScreen(for: caretRect)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    }

    // MARK: - Telemetry

    /// One structured record per inline paint so a misplaced ghost in a field report can be joined
    /// to the exact font, baseline, and frame that produced it.
    private func logInlinePresentation(_ session: InlineSession, panelFrame: CGRect) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        let firstRow = session.layout.rows.first
        let metadata: Logger.Metadata = [
            "stage": .string("overlay-present"),
            "mode": .string("inline"),
            "font_name": .string(session.fontResolution.font.fontName),
            "font_size": .stringConvertible(Double(session.fontResolution.font.pointSize)),
            "font_provenance": .string(session.fontResolution.provenance.rawValue),
            "width_agreement": .stringConvertible(Double(session.fontResolution.widthAgreement)),
            "baseline_offset": .stringConvertible(Double(session.baselineOffsetFromTop)),
            "baseline_source": .string(session.baselineSource.rawValue),
            "caret_x": .stringConvertible(Double(session.anchorCaretRect.minX)),
            "caret_x_reported": .stringConvertible(Double(session.geometry.caretRect.minX)),
            "caret_top": .stringConvertible(Double(session.anchorCaretRect.maxY)),
            "caret_h": .stringConvertible(Double(session.anchorCaretRect.height)),
            "caret_quality": .string(session.geometry.caretQuality.label),
            "web_field": .stringConvertible(session.geometry.isWebContentField),
            "consumed_utf16": .stringConvertible(session.consumedUTF16),
            "rows": .stringConvertible(session.layout.rows.count),
            "remaining_text": .string(String(session.layout.remainingText.prefix(40))),
            "truncated": .stringConvertible(session.layout.isTruncated),
            "trailing_content": .stringConvertible(session.geometry.hasTrailingContent),
            "end_of_line": .stringConvertible(session.geometry.isCaretAtEndOfLine),
            "row0_pen_x": .stringConvertible(Double(firstRow?.penX ?? 0)),
            "row0_baseline_y": .stringConvertible(Double(firstRow?.baselineY ?? 0)),
            "panel_x": .stringConvertible(Double(panelFrame.minX)),
            "panel_y": .stringConvertible(Double(panelFrame.minY)),
            "panel_w": .stringConvertible(Double(panelFrame.width)),
            "panel_h": .stringConvertible(Double(panelFrame.height)),
            "has_width_sample": .stringConvertible(session.geometry.hostTextMetrics?.sampleWidth != nil),
            "line_pitch": .stringConvertible(Double(session.geometry.hostTextMetrics?.linePitch ?? 0)),
            // The pitch the rows were actually laid out at (measured, remembered, or the caret box).
            "row_pitch": .stringConvertible(Double(
                session.layout.rows.count > 1 ? session.layout.rows[0].baselineY - session.layout.rows[1].baselineY : 0
            )),
            "line_left": .stringConvertible(Double(session.geometry.hostTextMetrics?.lineRect?.minX ?? 0)),
            "element_x": .stringConvertible(Double(session.geometry.elementFrameRect?.minX ?? 0)),
            "element_w": .stringConvertible(Double(session.geometry.elementFrameRect?.width ?? 0)),
            "band": .string(wrapBand(for: session.geometry).map { String(format: "%.1f-%.1f", $0.lowerBound, $0.upperBound) } ?? ""),
            "style_size": .stringConvertible(Double(session.geometry.resolvedFieldStyle?.fontPointSize ?? 0)),
            "style_name": .string(session.geometry.resolvedFieldStyle?.fontName ?? "")
        ]
        CotabbyLogger.suggestion.debug("Inline ghost presented", metadata: metadata)
    }

    private func logMirrorPresentation(
        geometry: SuggestionOverlayGeometry,
        reason: CompletionRenderMode.MirrorReason,
        panelFrame: CGRect
    ) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        let caretX = Double(geometry.caretRect.minX)
        let caretTop = Double(geometry.caretRect.maxY)
        let caretHeight = Double(geometry.caretRect.height)
        let panelX = Double(panelFrame.minX)
        let panelY = Double(panelFrame.minY)
        let metadata: Logger.Metadata = [
            "stage": .string("overlay-present"),
            "mode": .string("mirror"),
            "mirror_reason": .string(reason.rawValue),
            "caret_x": .stringConvertible(caretX),
            "caret_top": .stringConvertible(caretTop),
            "caret_h": .stringConvertible(caretHeight),
            "caret_quality": .string(geometry.caretQuality.label),
            "trailing_content": .stringConvertible(geometry.hasTrailingContent),
            "panel_x": .stringConvertible(panelX),
            "panel_y": .stringConvertible(panelY)
        ]
        CotabbyLogger.suggestion.debug("Mirror card presented", metadata: metadata)
    }

    private func logInlineDeclined(
        geometry: SuggestionOverlayGeometry,
        fontResolution: GhostFontResolver.Resolution,
        reason: CompletionRenderMode.MirrorReason
    ) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        CotabbyLogger.suggestion.debug(
            "Inline ghost declined; showing the card",
            metadata: [
                "stage": .string("overlay-inline-declined"),
                "reason": .string(reason.rawValue),
                "end_of_line": .stringConvertible(geometry.isCaretAtEndOfLine),
                "font_name": .string(fontResolution.font.fontName),
                "trailing_content": .stringConvertible(geometry.hasTrailingContent),
                "line_pitch_known": .stringConvertible(geometry.hostTextMetrics?.linePitch != nil),
                "web_field": .stringConvertible(geometry.isWebContentField)
            ]
        )
    }
}
