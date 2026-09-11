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
/// host's own font (`GhostFontResolver`) on the host's own baseline (`GhostBaselinePolicy`). The
/// controller keeps one `InlineSession` per shown suggestion: the full text, the anchor caret box it
/// was first shown at, and how much of it the host already contains. Acceptance and type-through
/// only advance that consumed count, so the glyphs that remain never move.
@MainActor
final class OverlayController: SuggestionOverlayControlling {
    var onStateChange: ((OverlayState) -> Void)?

    private let suggestionSettings: SuggestionSettingsModel

    /// Optional injection seam for tests. When set, `currentRenderModePolicy` returns this directly
    /// instead of building one from live settings. Production code leaves this nil.
    private let renderModePolicyOverride: CompletionRenderModePolicy?

    /// Built from the live `mirrorPreference` setting at call time rather than cached, so the user's
    /// Settings/menu-bar toggle takes effect on the very next presentation.
    private var currentRenderModePolicy: CompletionRenderModePolicy {
        if let renderModePolicyOverride {
            return renderModePolicyOverride
        }
        return CompletionRenderModePolicy(
            userPreference: suggestionSettings.mirrorPreference
        )
    }

    private(set) var state: OverlayState = .hidden(reason: "Overlay idle.") {
        didSet {
            onStateChange?(state)
        }
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
        /// "policy" (font metrics rule), "calibrated" (measured from a strip of the host's pixels),
        /// or "pixel" (read from the capture that placed the caret).
        var baselineSource: String
        var layout: GhostTextLayout
    }

    private var inlineSession: InlineSession?
    /// What each field's width samples have said about its typeface so far (see `TypefaceEvidence`).
    /// Keyed by the field's session identity, which survives the field growing as text wraps.
    private var typefaceEvidence: [UInt64: TypefaceEvidence] = [:]
    /// Per field: the host's size measured from its own caret's advance along a line, for a web
    /// field that reports no size (see `HostAdvanceFit`, `applyingHostAdvance`).
    private var hostAdvanceFits: [UInt64: HostAdvanceFit] = [:]
    /// Fields whose host named a face this Mac cannot load (Gemini's bundled Google Sans). The
    /// name is not on every snapshot's style (Chromium answers only a size for some caret
    /// positions), and one nameless snapshot was enough to let a width match flash Georgia in the
    /// middle of an otherwise settled field. Once seen, the fact holds for the field's life.
    private var unavailableNamedFaceFields: Set<UInt64> = []
    /// The face each host text style last settled on, for fields that have measured nothing yet
    /// (see `HostFaceMemory`). Lives as long as the controller, which is the app's lifetime.
    private var hostFaceMemory = HostFaceMemory()
    /// Which zoom ladder each host paints on, for snapping a pixel-matched size (see `HostZoomLadder`).
    private let hostZoomLadders = HostZoomLadderResolver()
    /// Measures the caret from the host's pixels for paragraphs AX exposes only as one union run
    /// (see `PixelCaretLocator`). Owned here because the measurement is a presentation concern:
    /// it decides where the ghost is drawn and whether it can be drawn inline at all.
    private let pixelCaretLocator = PixelCaretLocator()
    /// Retires a held presentation: a show or hide that arrives while the pixels are still being
    /// read bumps this, and the late measurement is dropped instead of resurrecting stale text.
    private var pixelCaretShowToken: UInt64 = 0
    /// True while the ghost has been taken down so a capture can read the run it covered; the
    /// held presentation puts it back. A typed-through advance meanwhile cannot render into the
    /// hidden panel and asks for a fresh present instead (`advanceInline`).
    private var panelHeldForCapture = false
    /// Measures web hosts' painted baselines; nil where screen capture is unwanted (tests).
    private let baselineCalibrator: HostBaselineCalibrator?
    /// The faces an Electron host ships in its bundle, for the pixel match (see the registry).
    private let hostBundledFonts = HostBundledFontRegistry()

    /// Where `hostFaceMemory` is kept between launches; nil keeps it in memory only (tests).
    private let faceMemoryDefaults: UserDefaults?
    static let faceMemoryDefaultsKey = "cotabbyHostFaceMemory"

    init(
        suggestionSettings: SuggestionSettingsModel,
        renderModePolicyOverride: CompletionRenderModePolicy? = nil,
        baselineCalibrator: HostBaselineCalibrator? = nil,
        faceMemoryDefaults: UserDefaults? = nil
    ) {
        self.suggestionSettings = suggestionSettings
        self.renderModePolicyOverride = renderModePolicyOverride
        self.baselineCalibrator = baselineCalibrator
        self.faceMemoryDefaults = faceMemoryDefaults
        self.hostFaceMemory = HostFaceMemory(restoring: faceMemoryDefaults?.data(forKey: Self.faceMemoryDefaultsKey))
        // Every fresh read of the host's caret is also a measurement of its text size (see
        // `recordAdvanceCapture`); `[weak self]` because the locator is owned by this controller.
        pixelCaretLocator.onFreshCapture = { [weak self] request, measurement in
            self?.recordAdvanceCapture(measurement, request: request)
        }
    }

    /// Saves the face memory after a record changed it (a new style settled, or its size or pitch
    /// moved): once per field at most, not once per presentation.
    private func saveFaceMemory() {
        faceMemoryDefaults?.set(hostFaceMemory.encoded(), forKey: Self.faceMemoryDefaultsKey)
    }

    private lazy var panel: OverlayPanel = {
        let panel = OverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // A non-activating panel lets Cotabby draw UI near the caret without stealing focus
        // from the app the user is actively typing into.
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        // Ghost text should feel like immediate ink at the caret, not a window being presented.
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }()

    /// Sizes and positions the overlay using the render mode the policy picks for this geometry.
    /// An inline pick that cannot be laid out honestly (the text needs a second row but the host
    /// exposed no line pitch, or it would paint over text after the caret) falls back to the card.
    func showSuggestion(_ text: String, geometry requestedGeometry: SuggestionOverlayGeometry) {
        guard !text.isEmpty else {
            hide(reason: "Overlay not shown because the suggestion was empty.")
            return
        }
        pixelCaretShowToken &+= 1
        let token = pixelCaretShowToken
        panelHeldForCapture = false
        var geometry = requestedGeometry
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
            return
        }
        // A caret inside a union-run paragraph is placed from the host's pixels, not from AX (which
        // has no answer there) and not from a font-metric layout (which put the ghost on top of the
        // host's own glyphs). The first presentation for a given paragraph text waits for the
        // capture, typically tens of milliseconds; later ones reuse it. If the pixels yield nothing
        // the presentation proceeds exactly as it would have without this service.
        //
        // A capture cannot see the run under Cotabby's own ghost (`panelCovers`). While the ghost
        // is up, a re-anchor for text typed on since the run's capture carries that caret forward
        // by the typed advance instead (`extrapolatedMeasurement`): the ghost's tail stays exactly
        // where it was drawn. Anything else (the paragraph wrapped, an edit elsewhere) takes the
        // ghost down for the read and puts it back where the pixels say. Re-anchoring to the
        // Accessibility estimate instead put the ghost four lines up, or off screen, on every
        // other keystroke of a typed-through suggestion (Obsidian, 2026-09-10).
        if let request = pixelCaretRequest(for: requestedGeometry) {
            let covered = panelCovers(request.runFrame)
            let measured = pixelCaretLocator.cachedMeasurement(for: request)
                ?? (covered ? pixelCaretLocator.extrapolatedMeasurement(for: request) : nil)
            if let measured {
                geometry = requestedGeometry.withPixelMeasuredCaret(
                    measured.caretRect,
                    lineRect: measured.lineRect,
                    linePitch: measured.linePitch,
                    baselineOffsetFromTop: measured.baselineOffsetFromTop,
                    lineInkWidth: measured.lineInkWidth
                )
            } else if !pixelCaretLocator.hasFailed(request) {
                if covered {
                    panelHeldForCapture = true
                    panel.orderOut(nil)
                    CotabbyLogger.suggestion.debug(
                        "Ghost taken down for a pixel caret read",
                        metadata: ["stage": .string("pixel-caret-hold"), "paragraph_chars": .stringConvertible(request.paragraphTextBeforeCaret.count)]
                    )
                }
                pixelCaretLocator.locate(request) { [weak self] _ in
                    guard let self, self.pixelCaretShowToken == token else { return }
                    self.showSuggestion(text, geometry: requestedGeometry)
                }
                return
            }
        }

        // Decide on the fade using the panel state captured *before* `state` is reassigned below, so
        // the animation plays only on a genuine appearance, never on a reposition or streamed update.
        let fadesIn = SuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: suggestionSettings.fadeInSuggestions,
            overlayWasVisible: state.isVisible,
            reduceMotionEnabled: reduceMotionEnabled
        )

        var mode = currentRenderModePolicy.mode(
            for: geometry,
            bundleIdentifier: geometry.bundleIdentifier
        )

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
            if let reason = showInline(text: text, geometry: geometry) {
                mode = .mirror(reason: reason)
                showMirror(text: text, geometry: geometry, reason: reason)
            }
        case .mirror(let reason):
            inlineSession = nil
            showMirror(text: text, geometry: geometry, reason: reason)
        }

        state = .visible(text: text, geometry: geometry, mode: mode)

        if fadesIn {
            fadeInPanel()
        }
    }

    /// Hides the floating panel and records why the overlay is no longer visible.
    func hide(reason: String) {
        pixelCaretShowToken &+= 1
        panelHeldForCapture = false
        CotabbyLogger.suggestion.debug("Overlay hidden", metadata: ["stage": .string("overlay-hide"), "reason": .string(reason)])
        panel.orderOut(nil)
        inlineSession = nil
        state = .hidden(reason: reason)
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

    /// Presents `text` anchored at the geometry's caret box as a fresh inline session. Returns the
    /// reason the card must take over instead when no honest inline layout exists for this text and
    /// geometry, nil when the ghost is up.
    private func showInline(text: String, geometry: SuggestionOverlayGeometry) -> CompletionRenderMode.MirrorReason? {
        let renderer: GhostBaselinePolicy.HostRenderer = geometry.isWebContentField ? .webEngine : .textKit
        let fontResolution = resolveFont(for: geometry, renderer: renderer)
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
        let anchorCaretRect = Self.refinedCaretRect(for: geometry, font: fontResolution)
        var session = InlineSession(
            fullText: text,
            consumedUTF16: 0,
            anchorCaretRect: anchorCaretRect,
            geometry: geometry,
            fontResolution: fontResolution,
            baselineOffsetFromTop: cachedOffset ?? policyOffset,
            baselineSource: pixelOffset != nil ? "pixel" : (cachedOffset == nil ? "policy" : "calibrated"),
            layout: GhostTextLayout(
                rows: [],
                font: fontResolution.font,
                boxHeight: 0,
                baselineOffsetFromTop: 0,
                keycapFrame: nil,
                isTruncated: false,
                contentBounds: .zero
            )
        )
        // Text follows the caret on its line: an inline ghost there could only sit on the host's own
        // characters, so the card under the caret shows the suggestion instead (the policy already
        // picks it under `auto`; this covers an explicit inline preference).
        guard geometry.isCaretAtEndOfLine else {
            logInlineDeclined(geometry: geometry, fontResolution: fontResolution, reason: .caretMidLine)
            return .caretMidLine
        }
        guard let layout = makeLayout(for: session) else {
            logInlineDeclined(geometry: geometry, fontResolution: fontResolution, reason: .inlineLayoutUnavailable)
            return .inlineLayoutUnavailable
        }
        session.layout = layout
        inlineSession = session
        renderInline(session)
        // Built after the render so the request knows where the panel now covers the host.
        if cachedOffset == nil || calibration?.matchTypeface == true,
           let calibration = calibrationRequest(for: geometry, resolution: fontResolution, policyOffset: policyOffset) {
            startCalibration(calibration, for: geometry)
        }
        return nil
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

    /// The host's face by report or measurement; for a web field the host never named, a face the
    /// host's own pixels matched earlier in this field replaces the system stand-in.
    /// The pixel measurement this geometry needs, or nil when AX already placed the caret. Only a
    /// caret at the end of its paragraph is measured: the paragraph's last inked line then ends at
    /// the caret. A caret inside the paragraph keeps the existing card, which is honest about not
    /// knowing where the caret is.
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
            lineLeft: line.minX,
            lineWidth: line.width,
            textBeforeCaretOnLine: text,
            font: resolveFont(for: geometry, renderer: .webEngine).font,
            isRightToLeft: geometry.isRightToLeft
        )
    }

    private func pixelCaretRequest(for geometry: SuggestionOverlayGeometry) -> PixelCaretLocator.Request? {
        guard !geometry.isRightToLeft else { return nil }
        // A caret with text after it on its line gets the card, whose anchor a union run's
        // Accessibility answer cannot give either (Claude's composer: the field's right edge); its
        // pixels can, from the text before it (see `PixelCaretLocator.Request.caretIsMidLine`).
        let midLine = !geometry.isCaretAtEndOfLine
        let renderer: GhostBaselinePolicy.HostRenderer = geometry.isWebContentField ? .webEngine : .textKit
        let resolution = resolveFont(for: geometry, renderer: renderer)
        let font = resolution.font
        // The captures of a web field that reports no size, in a face its pixels named, measure that
        // face's size (see `recordAdvanceCapture`).
        let recordsAdvance = !midLine && geometry.isWebContentField && geometry.resolvedFieldStyle?.fontPointSize == nil
            && resolution.provenance == .pixelMatched
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
            font: font
        )
    }

    private func resolveFont(
        for geometry: SuggestionOverlayGeometry,
        renderer: GhostBaselinePolicy.HostRenderer
    ) -> GhostFontResolver.Resolution {
        let resolution = GhostFontResolver.resolve(
            GhostFontResolver.Input(
                style: geometry.resolvedFieldStyle,
                hostMetrics: geometry.hostTextMetrics,
                caretBoxHeight: geometry.caretRect.height,
                renderer: renderer,
                sizeMultiplier: CGFloat(suggestionSettings.ghostTextSizeMultiplier)
            )
        )
        let judged = applyingTypefaceEvidence(resolution, for: geometry)
        let matched = Self.applyingMatchedTypeface(
            judged,
            match: baselineCalibrator?.cachedTypeface(for: typefaceKey(for: geometry)),
            hostNamesFace: Self.hostNamesFace(geometry),
            widthSample: heldWidthSample(for: geometry),
            sizeMultiplier: CGFloat(suggestionSettings.ghostTextSizeMultiplier),
            reportedSize: zoomStep(for: geometry).reportedSize,
            zoomKind: zoomStep(for: geometry).kind
        )
        let sized = applyingHostAdvance(matched, for: geometry)
        return rememberingHostFace(sized.resolution, advanceMeasured: sized.advanceMeasured, for: geometry)
    }

    /// A pixel-matched face in a web field that reports no size takes the size the field's own caret
    /// advance measured (`HostAdvanceFit`) or, until the field has measured one, the size an earlier
    /// field of the same style measured for the same face. The match's own size comes from a short
    /// strip whose size search is coarse, and its score says nothing about its size: Claude's Code
    /// composer matched 15.1585 with 0.97 where the host paints 15.336 (2026-09-11). A host that
    /// reports its size snaps the match to its zoom ladder instead (`applyingMatchedTypeface`).
    /// `advanceMeasured` marks the result for `HostFaceMemory`.
    private func applyingHostAdvance(
        _ resolution: GhostFontResolver.Resolution,
        for geometry: SuggestionOverlayGeometry
    ) -> (resolution: GhostFontResolver.Resolution, advanceMeasured: Bool) {
        guard geometry.isWebContentField, geometry.resolvedFieldStyle?.fontPointSize == nil,
              resolution.provenance == .pixelMatched else {
            return (resolution, false)
        }
        let size: CGFloat
        if let fit = hostAdvanceFits[geometry.focusedInputIdentityKey], fit.faceName == resolution.font.fontName,
           let adopted = fit.adopted {
            size = adopted.pointSize * max(CGFloat(suggestionSettings.ghostTextSizeMultiplier), 0.01)
        } else if let key = hostStyleKey(for: geometry), let remembered = hostFaceMemory.face(for: key),
                  remembered.advanceMeasured == true, remembered.fontName == resolution.font.fontName {
            // Kept with the multiplier applied, under a key that includes it.
            size = remembered.pointSize
        } else {
            return (resolution, false)
        }
        guard let font = GhostFontResolver.font(named: resolution.font.fontName, size: size) else {
            return (resolution, false)
        }
        return (GhostFontResolver.Resolution(font: font, provenance: .pixelMatched, widthAgreement: 1), true)
    }

    /// Feeds a fresh capture of the caret on a paragraph's first line to its field's advance fit
    /// (`HostAdvanceFit`): only for requests `pixelCaretRequest` marked, only a caret right after a
    /// glyph (a trailing space's advance is the ghost's own, not a measurement), and only the
    /// paragraph's first line, whose start every capture shares. The fit is taken in the ghost's face
    /// at the host size it assumes, the user's size multiplier divided out.
    private func recordAdvanceCapture(_ measurement: PixelCaretLocator.Measurement, request: PixelCaretLocator.Request) {
        // A mid-line caret is placed from the ghost face's own advances, so it measures nothing.
        guard request.recordsAdvance, !request.caretIsMidLine, measurement.lineIndex == 0, let face = request.font,
              let last = request.paragraphTextBeforeCaret.last, !last.isWhitespace,
              !request.paragraphTextBeforeCaret.contains(where: \.isNewline),
              let hostFace = GhostFontResolver.font(
                  named: face.fontName, size: face.pointSize / max(CGFloat(suggestionSettings.ghostTextSizeMultiplier), 0.01)
              )
        else { return }
        let identity = request.focusedInputIdentityKey
        var fit = hostAdvanceFits[identity] ?? HostAdvanceFit()
        let lineKey = "\(Int(request.runFrame.minX.rounded()))|\(Int(measurement.lineRect.maxY.rounded()))"
        let adopted = fit.record(
            text: request.paragraphTextBeforeCaret, caretX: measurement.caretRect.minX, lineKey: lineKey, face: hostFace
        )
        hostAdvanceFits[identity] = fit
        guard let adopted, CotabbyLogger.suggestion.logLevel <= .debug else { return }
        CotabbyLogger.suggestion.debug(
            "Host advance fit adopted",
            metadata: [
                "stage": .string("advance-fit"),
                "identity": .stringConvertible(identity),
                "font": .string(hostFace.fontName),
                "assumed_size": .stringConvertible(Double(hostFace.pointSize)),
                "fitted_size": .stringConvertible(Double(adopted.pointSize)),
                "span": .stringConvertible(Double(adopted.span)),
                "captures": .stringConvertible(adopted.captures),
                "refinements": .stringConvertible(fit.refinements)
            ]
        )
    }

    /// The reported CSS size and zoom ladder a web field's pixel-matched size snaps to (see
    /// `HostZoomLadder`). Every path that applies a pixel match goes through this, or a fresh
    /// calibration re-applies the raw fit for a presentation (Georgia 17.892 between 18.0 frames,
    /// once per streamed word, 2026-09-11).
    private func zoomStep(for geometry: SuggestionOverlayGeometry) -> (reportedSize: CGFloat?, kind: HostZoomLadder.Kind?) {
        guard geometry.isWebContentField else { return (nil, nil) }
        return (geometry.resolvedFieldStyle?.fontPointSize, hostZoomLadders.kind(forBundleIdentifier: geometry.bundleIdentifier))
    }

    /// The key `HostFaceMemory` files a field's host text style under.
    private func hostStyleKey(for geometry: SuggestionOverlayGeometry) -> HostFaceMemory.Key? {
        HostFaceMemory.Key(
            bundleIdentifier: geometry.bundleIdentifier,
            urlString: geometry.focusedURLString,
            isBrowser: BrowserAppDetector.isBrowser(bundleIdentifier: geometry.bundleIdentifier),
            reportedSize: geometry.resolvedFieldStyle?.fontPointSize,
            caretHeight: geometry.caretRect.height,
            sizeMultiplier: CGFloat(suggestionSettings.ghostTextSizeMultiplier)
        )
    }

    /// Records a field's settled face for its host's text style, and starts a field that has
    /// measured nothing yet in the face its host's last field settled on (see `HostFaceMemory`).
    /// A host that names its face never needs this: the resolver has that face already.
    private func rememberingHostFace(
        _ resolution: GhostFontResolver.Resolution,
        advanceMeasured: Bool = false,
        for geometry: SuggestionOverlayGeometry
    ) -> GhostFontResolver.Resolution {
        guard !Self.hostNamesFace(geometry), let key = hostStyleKey(for: geometry) else {
            return resolution
        }
        let adoptedSample = typefaceEvidence[geometry.focusedInputIdentityKey]?.scalingSample != nil
        if HostFaceMemory.isSettled(resolution.provenance, fieldAdoptedSample: adoptedSample) {
            let face = HostFaceMemory.Face(
                fontName: resolution.font.fontName, pointSize: resolution.font.pointSize, advanceMeasured: advanceMeasured ? true : nil
            )
            if hostFaceMemory.record(face, for: key) {
                saveFaceMemory()
            }
            return resolution
        }
        guard HostFaceMemory.yieldsToMemory(resolution.provenance),
              let remembered = hostFaceMemory.face(for: key),
              let font = GhostFontResolver.font(named: remembered.fontName, size: remembered.pointSize)
        else {
            return resolution
        }
        return GhostFontResolver.Resolution(font: font, provenance: .hostRemembered, widthAgreement: 1)
    }

    /// The width sample a pixel match is sized to: the one the field adopted (the first long
    /// enough, held for the field's life, see `TypefaceEvidence.scalingAdoptionLength`), so a
    /// sample that grows with every poll cannot resize the ghost between presentations.
    private func heldWidthSample(for geometry: SuggestionOverlayGeometry) -> TypefaceEvidence.Sample? {
        typefaceEvidence[geometry.focusedInputIdentityKey]?.scalingSample ?? Self.widthSample(of: geometry)
    }

    /// Whether the host told us its face (even one this Mac cannot load).
    private static func hostNamesFace(_ geometry: SuggestionOverlayGeometry) -> Bool {
        geometry.resolvedFieldStyle?.fontName != nil || geometry.resolvedFieldStyle?.fontFamily != nil
    }

    /// Holds a width-matched face steady across the samples a field produces over its life.
    ///
    /// Inert for a field measured once (the resolver's own decision stands untouched) and for any
    /// host whose named face loads. Two kinds of field reach the rules below:
    ///   - a host that named a face this Mac cannot load (Gemini names its bundled Google Sans):
    ///     once seen, the field renders the system face scaled to its longest sample for good,
    ///     even on snapshots whose style momentarily carries only a size, which is what let a width
    ///     match flash Georgia in the middle of an otherwise settled field;
    ///   - a size-only field that keeps producing new, different width samples, judged by
    ///     `TypefaceEvidence` (see the measured Gemini sequence there).
    private func applyingTypefaceEvidence(
        _ resolution: GhostFontResolver.Resolution,
        for geometry: SuggestionOverlayGeometry
    ) -> GhostFontResolver.Resolution {
        let identity = geometry.focusedInputIdentityKey
        switch resolution.provenance {
        case .hostSizeMatchedFamily, .hostSizeSystem, .hostSizeScaledSystem:
            break
        case .caretDerived, .caretDerivedCalibrated:
            // No face to judge here, but the field's samples are still recorded so the first one
            // long enough is held for a later pixel match to take its size from.
            if let sample = Self.widthSample(of: geometry) {
                var evidence = typefaceEvidence[identity] ?? TypefaceEvidence()
                let adoptedBefore = evidence.scalingSample
                evidence.record(sample, resolverFamily: nil)
                typefaceEvidence[identity] = evidence
                if let adopted = evidence.scalingSample, adopted != adoptedBefore {
                    Self.logAdoptedWidthSample(adopted, font: resolution.font, identity: identity)
                }
            }
            return resolution
        default:
            return resolution
        }
        let size = geometry.resolvedFieldStyle?.fontPointSize ?? resolution.font.pointSize
        let hostNamesFace = geometry.resolvedFieldStyle?.fontName != nil || geometry.resolvedFieldStyle?.fontFamily != nil
        if hostNamesFace, resolution.provenance != .hostSizeMatchedFamily {
            unavailableNamedFaceFields.insert(identity)
        }
        // An Electron host that ships its editor's face (Claude's composer: Anthropic Sans) names
        // none, and no installed family is it: a width match at the reported size is a near miss
        // (Verdana at 14 fits Anthropic Sans at 15.4 within a percent) that flashed Verdana and
        // Georgia between samples (2026-09-10). Such a field takes the honest stand-in, the system
        // face scaled to its own width, until the pixel match names the bundled face.
        if geometry.isWebContentField, !BrowserAppDetector.isBrowser(bundleIdentifier: geometry.bundleIdentifier),
           !hostBundledFonts.candidateFontNames(forBundleIdentifier: geometry.bundleIdentifier).isEmpty {
            unavailableNamedFaceFields.insert(identity)
        }
        var evidence = typefaceEvidence[identity] ?? TypefaceEvidence()
        let sample = Self.widthSample(of: geometry)
        if let sample {
            let adoptedBefore = evidence.scalingSample
            evidence.record(sample, resolverFamily: resolution.provenance == .hostSizeMatchedFamily ? resolution.font.familyName : nil)
            if let adopted = evidence.scalingSample, adopted != adoptedBefore {
                Self.logAdoptedWidthSample(adopted, font: resolution.font, identity: identity)
            }
        }
        if unavailableNamedFaceFields.contains(identity) {
            typefaceEvidence[identity] = evidence
            return Self.scaledSystemFace(size: size, evidence: evidence)
        }
        // A system face scaled to a width sample is scaled ONCE per field, to the first sample long
        // enough (`TypefaceEvidence.scalingAdoptionLength`): a sample that grows poll by poll (the
        // caret's own advance, `CaretAdvanceSampler`) would otherwise resize the ghost by a fraction
        // of a point on every presentation.
        // The adopted sample also outlives the caret sampler, which starts over at every line change
        // and edit: a presentation between two samples reached here as the unscaled reported size
        // and fell back to it (Claude's composer, 2026-09-10: the reported 14 for the painted 15.4,
        // 49 times in six minutes, each for the first dozen characters after a new line or edit).
        if resolution.provenance == .hostSizeScaledSystem || resolution.provenance == .hostSizeSystem,
           evidence.scalingSample != nil {
            typefaceEvidence[identity] = evidence
            return Self.scaledSystemFace(
                size: size, evidence: evidence, reportedSize: zoomStep(for: geometry).reportedSize, zoomKind: zoomStep(for: geometry).kind
            )
        }
        guard let sample else {
            return resolution
        }
        // The system face is the first candidate: while it fits every sample, another family that
        // also fits is a coin flip on whole-point widths, not evidence (see `resolveBySize`).
        let systemFamily = NSFont.systemFont(ofSize: size).familyName ?? ""
        let verdict = evidence.verdict(candidates: [systemFamily] + GhostFontResolver.candidateFamilies) { family, sample in
            family == systemFamily
                ? GhostFontResolver.systemFaceFits(sample: sample.text, width: sample.width, size: size)
                : GhostFontResolver.familyFits(family, sample: sample.text, width: sample.width, size: size)
        }
        typefaceEvidence[identity] = evidence
        CotabbyLogger.suggestion.debug(
            "Typeface evidence",
            metadata: [
                "stage": .string("typeface-evidence"),
                "identity": .stringConvertible(identity),
                "sample": .string(String(sample.text.prefix(32))),
                "resolver_family": .string(resolution.font.familyName ?? "-"),
                "resolver_provenance": .string(resolution.provenance.rawValue),
                "host_font": .string(geometry.resolvedFieldStyle?.fontName ?? geometry.resolvedFieldStyle?.fontFamily ?? "-"),
                "samples": .stringConvertible(evidence.samples.count),
                "adopted": .string(evidence.adoptedFamily ?? "-"),
                "verdict": .string("\(verdict)")
            ]
        )
        switch verdict {
        case .singleSample:
            return resolution
        case .family(let family) where family == systemFamily:
            guard resolution.font.familyName != systemFamily else { return resolution }
            return GhostFontResolver.Resolution(font: NSFont.systemFont(ofSize: size), provenance: .hostSizeSystem, widthAgreement: 1)
        case .family(let family):
            guard resolution.font.familyName != family, let font = GhostFontResolver.familyFont(family, size: size) else {
                return resolution
            }
            return GhostFontResolver.Resolution(
                font: font, provenance: .hostSizeMatchedFamily, widthAgreement: resolution.widthAgreement
            )
        case .undecidable:
            return Self.scaledSystemFace(size: size, evidence: evidence)
        }
    }

    /// One record per adopted sample: the text, the host's width of it, and what the current face
    /// makes of the same text, so a ghost sized from a bad sample can be traced to the sample.
    private static func logAdoptedWidthSample(_ sample: TypefaceEvidence.Sample, font: NSFont, identity: UInt64) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        CotabbyLogger.suggestion.debug(
            "Width sample adopted",
            metadata: [
                "stage": .string("width-sample"),
                "identity": .stringConvertible(identity),
                "sample": .string(String(sample.text.prefix(40))),
                "chars": .stringConvertible(sample.text.count),
                "host_width": .stringConvertible(Double(sample.width)),
                "font": .string(font.fontName),
                "font_size": .stringConvertible(Double(font.pointSize)),
                "font_width": .stringConvertible(Double(GhostFontResolver.width(of: sample.text, font: font)))
            ]
        )
    }

    /// The host's measured width sample for this geometry, when it has one.
    private static func widthSample(of geometry: SuggestionOverlayGeometry) -> TypefaceEvidence.Sample? {
        guard let text = geometry.hostTextMetrics?.sampleText, let width = geometry.hostTextMetrics?.sampleWidth, width > 0 else {
            return nil
        }
        return TypefaceEvidence.Sample(text: text, width: width)
    }

    /// The system face at the host's size, scaled to the field's adopted sample (the first one long
    /// enough, held for the field's life, see `TypefaceEvidence.scalingAdoptionLength`). Until one
    /// arrives the reported size is used as is: a size that followed every longer sample resized
    /// Gemini's ghost three times in one sentence.
    ///
    /// Where the host's face is judged to be the system face itself (`reportedSize` and `zoomKind`
    /// given), the host paints the reported size times a zoom step, and a scaled size within a
    /// percent of such a product is that product, as for a pixel match (`applyingMatchedTypeface`):
    /// a dozen-character sample of whole-point carets carries about half a percent, which showed as
    /// 15.06 between the reported 15.0 and the pixel match's 15.0 in a system-font Chrome field
    /// (three presentations, 2026-09-11). As a stand-in for another face (one the host names but
    /// this Mac lacks, or one no family fits) the scaled size is that face's advance, not a size the
    /// host set, and it is kept as the sample gives it.
    static func scaledSystemFace(
        size: CGFloat, evidence: TypefaceEvidence, reportedSize: CGFloat? = nil, zoomKind: HostZoomLadder.Kind? = nil
    ) -> GhostFontResolver.Resolution {
        guard let sample = evidence.scalingSample else {
            return GhostFontResolver.Resolution(font: NSFont.systemFont(ofSize: size), provenance: .hostSizeSystem, widthAgreement: 1)
        }
        let scaled = GhostFontResolver.scaledSystemResolution(size: size, sample: sample.text, width: sample.width)
        guard let reportedSize, let zoomKind,
              let snapped = HostZoomLadder.snappedSize(measured: scaled.font.pointSize, reported: reportedSize, kind: zoomKind),
              snapped != scaled.font.pointSize
        else {
            return scaled
        }
        let font = GhostFontResolver.resized(scaled.font, to: snapped)
        let measured = GhostFontResolver.width(of: sample.text, font: font)
        return GhostFontResolver.Resolution(
            font: font, provenance: .hostSizeScaledSystem, widthAgreement: measured > 0 ? sample.width / measured : 1
        )
    }

    /// The face and size the host's pixels matched replace a stand-in face, and a width-matched
    /// family too: a strip of glyph shapes is stronger evidence than one or two whole-point width
    /// samples (measured 2026-09-10: Chrome's Helvetica input width-matched Trebuchet MS for 108
    /// presentations between pixel matches of Arial and Helvetica Neue). A face the host named is
    /// never replaced, even one this Mac cannot load: the scaled system face is the honest stand-in
    /// there (Gemini's Google Sans), and a near miss from the candidate list would look worse.
    ///
    /// A match must also agree with the width the host itself rendered, when one was measured: the
    /// advance is the host's own metric, and a face whose advance of the sample text is off by more
    /// than `matchedAdvanceTolerance` is at the wrong size whatever its shapes scored (Claude's
    /// composer, 2026-09-10: the system face at 16.15 scored 0.89 on Anthropic Sans set at 15.4,
    /// five percent wider than the caret's own travel). Within that tolerance the pixels name the
    /// face and the sample sets its size: a web engine renders a face without the tracking
    /// CoreText applies (Obsidian's system face at 16 advanced 1.5% less than CoreText's), and a
    /// ghost whose advances are the host's lands every typed-through and accepted word where the
    /// host puts it, at a glyph size a fraction of a pixel off.
    ///
    /// A web host paints its reported CSS size (`reportedSize`) times a factor from its zoom ladder
    /// (`zoomKind`), and a matched size within a percent of such a product is that product (see
    /// `HostZoomLadder`): the fit wanders by about half a percent between fields, and Obsidian's
    /// 16px text matched at 16.10 drifted two device pixels by a line's end where 15.99 held every
    /// word within one (2026-09-11).
    static func applyingMatchedTypeface(
        _ resolution: GhostFontResolver.Resolution,
        match: HostBaselineCalibrator.TypefaceMatchRecord?,
        hostNamesFace: Bool,
        widthSample: TypefaceEvidence.Sample? = nil,
        sizeMultiplier: CGFloat,
        reportedSize: CGFloat? = nil,
        zoomKind: HostZoomLadder.Kind? = nil
    ) -> GhostFontResolver.Resolution {
        func onLadder(_ size: CGFloat) -> CGFloat {
            guard let reportedSize, let zoomKind else { return size }
            return HostZoomLadder.snappedSize(measured: size, reported: reportedSize, kind: zoomKind) ?? size
        }
        guard let match, !hostNamesFace, Self.acceptsPixelMatch(resolution.provenance),
              let unscaled = GhostFontResolver.font(named: match.fontName, size: match.pointSize),
              let matched = GhostFontResolver.font(named: match.fontName, size: onLadder(match.pointSize) * max(sizeMultiplier, 0.01))
        else {
            return resolution
        }
        // A settled match (`HostBaselineCalibrator.settledTypefaceScore`) is the host's face at
        // the host's size to within a few hundredths of a point (the correlation falls off a fifth
        // of the scale a sixth of a point away): it keeps its own size and needs no sample's
        // agreement. Measured 2026-09-10 in Chrome's contenteditable: a first twelve-character
        // caret sample one advance short refused the system face matched at 15.05 with 0.96 and
        // left the ghost at 13.7 for the field's life.
        if let widthSample, widthSample.width > 0, !widthSample.text.isEmpty,
           match.score < HostBaselineCalibrator.settledTypefaceScore {
            let advance = GhostFontResolver.width(of: widthSample.text, font: unscaled)
            guard advance > 0, abs(advance / widthSample.width - 1) <= Self.matchedAdvanceTolerance else {
                return resolution
            }
            let fitted = GhostFontResolver.scaled(unscaled, toSample: widthSample.text, width: widthSample.width)
            let sized = GhostFontResolver.resized(fitted, to: onLadder(fitted.pointSize) * max(sizeMultiplier, 0.01))
            return GhostFontResolver.Resolution(font: sized, provenance: .pixelMatched, widthAgreement: 1)
        }
        return GhostFontResolver.Resolution(font: matched, provenance: .pixelMatched, widthAgreement: 1)
    }

    /// Relative disagreement between a pixel-matched face's advance and the host's measured
    /// sample above which the match is not this text's size. A twelve-character sample of
    /// whole-pixel caret positions carries about a percent of rounding.
    static let matchedAdvanceTolerance: CGFloat = 0.02

    /// Provenances the pixel match outranks: every stand-in, a width-matched family, and an
    /// earlier pixel match (the field's record may have improved).
    static func acceptsPixelMatch(_ provenance: GhostFontResolver.Provenance) -> Bool {
        provenance.isFallbackFace || provenance == .hostSizeMatchedFamily || provenance == .pixelMatched
    }

    private func typefaceKey(for geometry: SuggestionOverlayGeometry) -> HostBaselineCalibrator.TypefaceKey {
        HostBaselineCalibrator.TypefaceKey(focusedInputIdentityKey: geometry.focusedInputIdentityKey)
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
            elementFrameRect: context.elementFrameRect,
            lineTextBeforeCaret: GhostCaretRefinement.paragraphTextBeforeCaret(in: context.precedingText),
            wrappedRun: context.observedContentEdges?.wrappedRun
        )
        // The capture runs while the model generates, so the first ghost for this text already
        // knows its caret and nothing is held at presentation time.
        if let request = pixelCaretRequest(for: geometry),
           pixelCaretLocator.cachedMeasurement(for: request) == nil, !pixelCaretLocator.hasFailed(request),
           !panelCovers(request.runFrame) {
            pixelCaretLocator.locate(request) { _ in }
        }
        let renderer: GhostBaselinePolicy.HostRenderer = context.isWebContentField ? .webEngine : .textKit
        let fontResolution = resolveFont(for: geometry, renderer: renderer)
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
        let matchTypeface = !Self.hostNamesFace(geometry) && Self.acceptsPixelMatch(resolution.provenance)
        // A browser's bundle holds no page fonts; an Electron app's holds the faces its editor
        // is set in (Claude's composer: Anthropic Sans), which no installed candidate approximates.
        let hostFontNames = matchTypeface && geometry.isWebContentField && !BrowserAppDetector.isBrowser(bundleIdentifier: geometry.bundleIdentifier)
            ? hostBundledFonts.candidateFontNames(forBundleIdentifier: geometry.bundleIdentifier)
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
            sizeIsReported: Self.sizeIsReported(resolution.provenance),
            sizeIsMeasured: Self.sizeIsMeasured(resolution.provenance),
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

    /// Whether the resolution's size came from the host (a plausible reported size, possibly
    /// scaled to a width sample) rather than from the caret box.
    static func sizeIsReported(_ provenance: GhostFontResolver.Provenance) -> Bool {
        switch provenance {
        case .hostFace, .hostFamily, .hostSizeMatchedFamily, .hostSizeScaledSystem, .hostSizeSystem, .hostFaceScaled, .pixelMatched,
             .hostRemembered:
            return true
        case .caretDerived, .caretDerivedCalibrated:
            return false
        }
    }

    /// Whether the resolution's size was scaled to a width the host rendered (a bounds query or
    /// the caret's own advance), which pins it within a couple of percent whatever the host said.
    static func sizeIsMeasured(_ provenance: GhostFontResolver.Provenance) -> Bool {
        switch provenance {
        case .hostSizeScaledSystem, .hostFaceScaled, .caretDerivedCalibrated:
            return true
        case .hostFace, .hostFamily, .hostSizeMatchedFamily, .hostSizeSystem, .pixelMatched, .caretDerived, .hostRemembered:
            return false
        }
    }

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
            guard let self, var session = self.inlineSession,
                  case .visible(_, _, let mode) = self.state, case .inline = mode,
                  session.geometry.focusedInputIdentityKey == geometry.focusedInputIdentityKey,
                  session.anchorCaretRect.maxY == geometry.caretRect.maxY
            else {
                return
            }
            var changed = false
            if session.geometry.pixelBaselineOffset == nil, abs(session.baselineOffsetFromTop - calibration.baselineOffset) > 0.01 {
                session.baselineOffsetFromTop = calibration.baselineOffset
                session.baselineSource = "calibrated"
                changed = true
            }
            let zoom = self.zoomStep(for: geometry)
            let rematched = Self.applyingMatchedTypeface(
                session.fontResolution,
                match: calibration.typefaceMatch,
                hostNamesFace: Self.hostNamesFace(geometry),
                widthSample: self.heldWidthSample(for: geometry),
                sizeMultiplier: CGFloat(self.suggestionSettings.ghostTextSizeMultiplier),
                reportedSize: zoom.reportedSize,
                zoomKind: zoom.kind
            )
            if rematched.font != session.fontResolution.font {
                session.fontResolution = rematched
                changed = true
            }
            guard changed, let layout = self.makeLayout(for: session) else { return }
            session.layout = layout
            self.inlineSession = session
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
        guard !panelHeldForCapture,
              var session = inlineSession, case .visible(_, _, let mode) = state, case .inline = mode else {
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
        inlineSession = session
        renderInline(session)

        // The geometry the coordinator sees keeps its caret at the predicted insertion point so the
        // stability gate compares fresh AX carets against where the ghost actually is.
        let advancedCaret = predictedCaretRect(for: session)
        state = .visible(text: remainingText, geometry: session.geometry.withCaretRect(advancedCaret), mode: .inline)
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
        let geometry = session.geometry
        let acceptanceHintLabel = suggestionSettings.acceptanceHintLabel(
            forBundleIdentifier: geometry.bundleIdentifier
        )
        let keycapWidth = acceptanceHintLabel.map(GhostTextPanelView.keycapWidth(for:)) ?? 0
        return GhostTextLayout.make(
            GhostTextLayout.Input(
                fullText: session.fullText,
                consumedUTF16: session.consumedUTF16,
                font: session.fontResolution.font,
                anchorTopLeft: CGPoint(x: session.anchorCaretRect.minX, y: session.anchorCaretRect.maxY),
                boxHeight: session.anchorCaretRect.height,
                baselineOffsetFromTop: session.baselineOffsetFromTop,
                linePitch: linePitch(for: geometry, fontSize: session.fontResolution.font.pointSize),
                wrapBand: wrapBand(for: geometry),
                isRightToLeft: geometry.isRightToLeft,
                // A second row would paint over the host's own following lines; with text below
                // the caret the ghost keeps to the caret row and reveals the rest as it is accepted.
                allowsMultipleRows: !geometry.hasTrailingContent,
                keycapWidth: keycapWidth
            )
        )
    }

    /// Vertical distance between the host's lines: measured when the host let us (line APIs, a
    /// character-bounds scan, sibling text runs), else the caret box height. For a TextKit host the
    /// caret box IS the line fragment, so that is exact; for a web engine it is the content box and
    /// can be a pixel short of the line box (Chrome: 15 or 16 for a 16.25 pitch), which matters
    /// only until the field has a second line to measure. A row placed a pixel off beats the card:
    /// measured live, the card at the end of a first line was the single most disliked behavior.
    ///
    /// A pitch no text of the ghost's size can have (`HostFaceMemory.isPlausiblePitch`) is a misread
    /// and is neither used nor remembered: Obsidian's one-line runs three lines apart once gave 72pt
    /// for 16pt text, and a capital alone on a fresh line in Claude gave 12.5pt for 15.3pt.
    private func linePitch(for geometry: SuggestionOverlayGeometry, fontSize: CGFloat) -> CGFloat? {
        let key = geometry.isWebContentField ? hostStyleKey(for: geometry) : nil
        // The ghost's size carries the user's multiplier; the host's line-height does not.
        let hostSize = fontSize / max(CGFloat(suggestionSettings.ghostTextSizeMultiplier), 0.01)
        if let measured = geometry.hostTextMetrics?.linePitch, measured > 0,
           HostFaceMemory.isPlausiblePitch(measured, pointSize: hostSize) {
            if let key {
                if hostFaceMemory.recordPitch(measured, for: key) {
                    saveFaceMemory()
                }
            }
            return measured
        }
        guard geometry.caretRect.height > 0, geometry.caretQuality != .estimated else {
            return nil
        }
        // A web engine's caret box is the glyph box, shorter than the line (Claude's composer: 19
        // for 22); a field of the same style that did measure its pitch knows the line-height.
        if let key, let remembered = hostFaceMemory.pitch(for: key),
           HostFaceMemory.isPlausiblePitch(remembered, pointSize: hostSize) {
            return remembered
        }
        return geometry.caretRect.height
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
            let green = isDarkAppearance
                ? NSColor(srgbRed: 0.45, green: 0.85, blue: 0.45, alpha: 1)
                : NSColor(srgbRed: 0.15, green: 0.60, blue: 0.20, alpha: 1)
            return green.withAlphaComponent(opacity)
        }
        let base = SuggestionTextColorCodec.nsColor(fromHex: suggestionSettings.customSuggestionTextColorHex)
            ?? fieldGhostColor(from: geometry.resolvedFieldStyle)
            ?? (isDarkAppearance ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.45, alpha: 1))
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
            sizeMultiplier: CGFloat(suggestionSettings.ghostTextSizeMultiplier),
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
            "baseline_source": .string(session.baselineSource),
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
        CotabbyLogger.suggestion.debug(
            "Mirror card presented",
            metadata: [
                "stage": .string("overlay-present"),
                "mode": .string("mirror"),
                "mirror_reason": .string(reason.rawValue),
                "caret_x": .stringConvertible(Double(geometry.caretRect.minX)),
                "caret_top": .stringConvertible(Double(geometry.caretRect.maxY)),
                "caret_h": .stringConvertible(Double(geometry.caretRect.height)),
                "caret_quality": .string(geometry.caretQuality.label),
                "trailing_content": .stringConvertible(geometry.hasTrailingContent),
                "panel_x": .stringConvertible(Double(panelFrame.minX)),
                "panel_y": .stringConvertible(Double(panelFrame.minY))
            ]
        )
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

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
