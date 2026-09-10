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
        /// The field's measured background, once known; rows over host text get opaque bands in it.
        var hostBackground: HostBaselineCalibrator.HostBackground?
        var layout: GhostTextLayout
    }

    private var inlineSession: InlineSession?
    /// What each field's width samples have said about its typeface so far (see `TypefaceEvidence`).
    /// Keyed by the field's session identity, which survives the field growing as text wraps.
    private var typefaceEvidence: [UInt64: TypefaceEvidence] = [:]
    /// Fields whose host named a face this Mac cannot load (Gemini's bundled Google Sans). The
    /// name is not on every snapshot's style (Chromium answers only a size for some caret
    /// positions), and one nameless snapshot was enough to let a width match flash Georgia in the
    /// middle of an otherwise settled field. Once seen, the fact holds for the field's life.
    private var unavailableNamedFaceFields: Set<UInt64> = []
    /// Measures the caret from the host's pixels for paragraphs AX exposes only as one union run
    /// (see `PixelCaretLocator`). Owned here because the measurement is a presentation concern:
    /// it decides where the ghost is drawn and whether it can be drawn inline at all.
    private let pixelCaretLocator = PixelCaretLocator()
    /// Retires a held presentation: a show or hide that arrives while the pixels are still being
    /// read bumps this, and the late measurement is dropped instead of resurrecting stale text.
    private var pixelCaretShowToken: UInt64 = 0
    /// Measures web hosts' painted baselines; nil where screen capture is unwanted (tests).
    private let baselineCalibrator: HostBaselineCalibrator?

    init(
        suggestionSettings: SuggestionSettingsModel,
        renderModePolicyOverride: CompletionRenderModePolicy? = nil,
        baselineCalibrator: HostBaselineCalibrator? = nil
    ) {
        self.suggestionSettings = suggestionSettings
        self.renderModePolicyOverride = renderModePolicyOverride
        self.baselineCalibrator = baselineCalibrator
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
        var geometry = requestedGeometry
        // A caret inside a union-run paragraph is placed from the host's pixels, not from AX (which
        // has no answer there) and not from a font-metric layout (which put the ghost on top of the
        // host's own glyphs). The first presentation for a given paragraph text waits for the
        // capture, typically tens of milliseconds; later ones reuse it. If the pixels yield nothing
        // the presentation proceeds exactly as it would have without this service.
        if let request = pixelCaretRequest(for: requestedGeometry) {
            if let measured = pixelCaretLocator.cachedMeasurement(for: request) {
                geometry = requestedGeometry.withPixelMeasuredCaret(
                    measured.caretRect,
                    lineRect: measured.lineRect,
                    linePitch: measured.linePitch,
                    baselineOffsetFromTop: measured.baselineOffsetFromTop,
                    lineInkWidth: measured.lineInkWidth
                )
            } else if !pixelCaretLocator.hasFailed(request) {
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
        let background = baselineCalibrator?.cachedBackground(for: geometry.focusedInputIdentityKey)
        if background == nil {
            startBackgroundMeasurement(for: geometry)
        }
        var session = InlineSession(
            fullText: text,
            consumedUTF16: 0,
            anchorCaretRect: anchorCaretRect,
            geometry: geometry,
            fontResolution: fontResolution,
            baselineOffsetFromTop: cachedOffset ?? policyOffset,
            baselineSource: pixelOffset != nil ? "pixel" : (cachedOffset == nil ? "policy" : "calibrated"),
            hostBackground: background,
            layout: GhostTextLayout(
                rows: [],
                font: fontResolution.font,
                boxHeight: 0,
                baselineOffsetFromTop: 0,
                keycapFrame: nil,
                rowBands: [],
                isTruncated: false,
                contentBounds: .zero
            )
        )
        guard let layout = makeLayout(for: session) else {
            logInlineDeclined(geometry: geometry, fontResolution: fontResolution, reason: .inlineLayoutUnavailable)
            return .inlineLayoutUnavailable
        }
        // Text follows the caret on its line. Only a band in the host's own background color makes
        // an inline ghost readable there; until one can be painted (the background is still being
        // measured, Screen Recording is off, or the band edge is unknown) the card shows it.
        if !geometry.isCaretAtEndOfLine, !layout.rowBands.contains(where: \.isCaretRow) {
            logInlineDeclined(geometry: geometry, fontResolution: fontResolution, reason: .caretMidLine)
            return .caretMidLine
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
    /// text's own advance (see `GhostCaretRefinement`). Native hosts report exact carets already.
    private static func refinedCaretRect(for geometry: SuggestionOverlayGeometry, font: GhostFontResolver.Resolution) -> CGRect {
        guard geometry.isWebContentField, !font.provenance.isFallbackFace,
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

    private func pixelCaretRequest(for geometry: SuggestionOverlayGeometry) -> PixelCaretLocator.Request? {
        guard geometry.isCaretAtEndOfLine, !geometry.isRightToLeft else { return nil }
        let renderer: GhostBaselinePolicy.HostRenderer = geometry.isWebContentField ? .webEngine : .textKit
        let font = resolveFont(for: geometry, renderer: renderer).font
        if let wrapped = geometry.wrappedRun {
            return PixelCaretLocator.Request(
                focusedInputIdentityKey: geometry.focusedInputIdentityKey,
                runFrame: wrapped.frame,
                paragraphTextBeforeCaret: wrapped.paragraphTextBeforeCaret,
                siblingLinePitch: geometry.hostTextMetrics?.linePitch,
                siblingLineBoxHeight: geometry.hostTextMetrics?.lineRect?.height,
                spaceAdvance: GhostFontResolver.width(of: " ", font: font)
            )
        }
        // A single-line field whose caret AX could only estimate (Chrome's address bar answers no
        // bounds query at all, measured 2026-09-10): the field frame is the line, and the caret is
        // where its ink ends. Estimated carets otherwise go to the card.
        guard geometry.caretQuality == .estimated || geometry.caretQuality == .layoutEstimated,
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
            // A fixed fraction of the field, not the estimate's own height: the estimate alternated
            // between 16 and 18pt for Chrome's 24pt address bar (measured 2026-09-10) and the ghost's
            // derived size flipped with it. The pixel match settles the size; this box only has to
            // be the same every time.
            singleLineCaretHeight: (frame.height * Self.singleLineCaretBoxFraction * 2).rounded() / 2
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
        return Self.applyingMatchedTypeface(
            judged,
            match: baselineCalibrator?.cachedTypeface(for: typefaceKey(for: geometry)),
            hostNamesFace: Self.hostNamesFace(geometry),
            sizeMultiplier: CGFloat(suggestionSettings.ghostTextSizeMultiplier)
        )
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
        switch resolution.provenance {
        case .hostSizeMatchedFamily, .hostSizeSystem, .hostSizeScaledSystem:
            break
        default:
            return resolution
        }
        let identity = geometry.focusedInputIdentityKey
        let size = geometry.resolvedFieldStyle?.fontPointSize ?? resolution.font.pointSize
        let hostNamesFace = geometry.resolvedFieldStyle?.fontName != nil || geometry.resolvedFieldStyle?.fontFamily != nil
        if hostNamesFace, resolution.provenance != .hostSizeMatchedFamily {
            unavailableNamedFaceFields.insert(identity)
        }
        var evidence = typefaceEvidence[identity] ?? TypefaceEvidence()
        let sample = Self.widthSample(of: geometry)
        if let sample {
            evidence.record(sample, resolverFamily: resolution.provenance == .hostSizeMatchedFamily ? resolution.font.familyName : nil)
        }
        if unavailableNamedFaceFields.contains(identity) {
            typefaceEvidence[identity] = evidence
            return Self.scaledSystemFace(size: size, evidence: evidence)
        }
        guard let sample else {
            return resolution
        }
        let verdict = evidence.verdict(candidates: GhostFontResolver.candidateFamilies) { family, sample in
            GhostFontResolver.familyFits(family, sample: sample.text, width: sample.width, size: size)
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
    private static func scaledSystemFace(size: CGFloat, evidence: TypefaceEvidence) -> GhostFontResolver.Resolution {
        guard let sample = evidence.scalingSample else {
            return GhostFontResolver.Resolution(font: NSFont.systemFont(ofSize: size), provenance: .hostSizeSystem, widthAgreement: 1)
        }
        return GhostFontResolver.scaledSystemResolution(size: size, sample: sample.text, width: sample.width)
    }

    /// The face and size the host's pixels matched replace a stand-in face, and a width-matched
    /// family too: a strip of glyph shapes is stronger evidence than one or two whole-point width
    /// samples (measured 2026-09-10: Chrome's Helvetica input width-matched Trebuchet MS for 108
    /// presentations between pixel matches of Arial and Helvetica Neue). A face the host named is
    /// never replaced, even one this Mac cannot load: the scaled system face is the honest stand-in
    /// there (Gemini's Google Sans), and a near miss from the candidate list would look worse.
    private static func applyingMatchedTypeface(
        _ resolution: GhostFontResolver.Resolution,
        match: HostBaselineCalibrator.TypefaceMatchRecord?,
        hostNamesFace: Bool,
        sizeMultiplier: CGFloat
    ) -> GhostFontResolver.Resolution {
        guard let match, !hostNamesFace, Self.acceptsPixelMatch(resolution.provenance),
              let matched = GhostFontResolver.font(named: match.fontName, size: match.pointSize * max(sizeMultiplier, 0.01))
        else {
            return resolution
        }
        return GhostFontResolver.Resolution(font: matched, provenance: .pixelMatched, widthAgreement: 1)
    }

    /// Provenances the pixel match outranks: every stand-in, a width-matched family, and an
    /// earlier pixel match (the field's record may have improved).
    static func acceptsPixelMatch(_ provenance: GhostFontResolver.Provenance) -> Bool {
        provenance.isFallbackFace || provenance == .hostSizeMatchedFamily || provenance == .pixelMatched
    }

    private func typefaceKey(for geometry: SuggestionOverlayGeometry) -> HostBaselineCalibrator.TypefaceKey {
        HostBaselineCalibrator.TypefaceKey(focusedInputIdentityKey: geometry.focusedInputIdentityKey)
    }

    /// Starts measuring the host's baseline for the line the caret is on (and the field's background
    /// color), while the model is still generating, so the first ghost on that line already sits on
    /// the measured baseline and can paint its bands.
    func prepareInlinePresentation(for context: FocusedInputContext) {
        guard baselineCalibrator != nil else { return }
        let geometry = SuggestionOverlayGeometry(
            caretRect: context.caretRect,
            inputFrameRect: context.inputFrameRect,
            caretQuality: context.caretQuality,
            observedCharWidth: context.observedCharWidth,
            isRightToLeft: false,
            focusChangeSequence: context.focusChangeSequence,
            focusedInputIdentityKey: context.focusedInputIdentityKey,
            resolvedFieldStyle: context.resolvedFieldStyle,
            hostTextMetrics: context.hostTextMetrics,
            isWebContentField: context.isWebContentField,
            elementFrameRect: context.elementFrameRect,
            lineTextBeforeCaret: GhostCaretRefinement.paragraphTextBeforeCaret(in: context.precedingText),
            wrappedRun: context.observedContentEdges?.wrappedRun
        )
        // The capture runs while the model generates, so the first ghost for this text already
        // knows its caret and nothing is held at presentation time.
        if let request = pixelCaretRequest(for: geometry),
           pixelCaretLocator.cachedMeasurement(for: request) == nil, !pixelCaretLocator.hasFailed(request) {
            pixelCaretLocator.locate(request) { _ in }
        }
        startBackgroundMeasurement(for: geometry)
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
            matchTypeface: !Self.hostNamesFace(geometry) && Self.acceptsPixelMatch(resolution.provenance),
            sizeIsReported: Self.sizeIsReported(resolution.provenance),
            lineInkWidth: geometry.pixelLineInkWidth,
            occludedFrom: occludedFrom
        )
    }

    /// How far left of the caret a calibration strip can reach; the panel matters only within it.
    private var maximumStripReach: CGFloat { HostBaselineCalibrator.maximumStripWidth + 4 }
    /// Points the excluded region was measured to extend past the panel's own frame.
    private static let occlusionMargin: CGFloat = 4

    /// Whether the resolution's size came from the host (a plausible reported size, possibly
    /// scaled to a width sample) rather than from the caret box.
    static func sizeIsReported(_ provenance: GhostFontResolver.Provenance) -> Bool {
        switch provenance {
        case .hostFace, .hostFamily, .hostSizeMatchedFamily, .hostSizeScaledSystem, .hostSizeSystem, .hostFaceScaled, .pixelMatched:
            return true
        case .caretDerived, .caretDerivedCalibrated:
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
            let rematched = Self.applyingMatchedTypeface(
                session.fontResolution,
                match: calibration.typefaceMatch,
                hostNamesFace: Self.hostNamesFace(geometry),
                sizeMultiplier: CGFloat(self.suggestionSettings.ghostTextSizeMultiplier)
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

    /// Measures the field's background once per field. When it arrives, a visible ghost gets its
    /// bands, and a card that was up only because no band could be painted (the caret row could not
    /// be covered, or the text needed rows over the host's following lines) is presented again,
    /// inline this time.
    private func startBackgroundMeasurement(for geometry: SuggestionOverlayGeometry) {
        guard let baselineCalibrator, baselineCalibrator.cachedBackground(for: geometry.focusedInputIdentityKey) == nil else {
            return
        }
        let identity = geometry.focusedInputIdentityKey
        let request = HostBaselineCalibrator.BackgroundRequest(
            focusedInputIdentityKey: identity,
            caretRect: geometry.caretRect,
            linePitch: linePitch(for: geometry),
            contentLeft: geometry.hostTextMetrics?.lineRect?.minX ?? geometry.elementFrameRect?.minX,
            contentRight: geometry.elementFrameRect?.maxX,
            contentBottom: geometry.elementFrameRect?.minY
        )
        baselineCalibrator.measureBackground(request) { [weak self] background in
            guard let self else { return }
            switch self.state {
            case .visible(let text, let visibleGeometry, .mirror(let reason))
                where visibleGeometry.focusedInputIdentityKey == identity
                    && (reason == .caretMidLine || reason == .inlineLayoutUnavailable):
                self.showSuggestion(text, geometry: visibleGeometry)
            case .visible(_, _, .inline):
                guard var session = self.inlineSession, session.geometry.focusedInputIdentityKey == identity,
                      session.hostBackground == nil
                else { return }
                session.hostBackground = background
                guard let layout = self.makeLayout(for: session) else { return }
                session.layout = layout
                self.inlineSession = session
                self.renderInline(session)
            default:
                return
            }
        }
    }

    /// Advances the visible inline ghost past `insertedText` (typed through or accepted) by moving
    /// the consumed boundary inside the same session. No Accessibility geometry is read, so the
    /// rows that stay visible keep their exact pixels. Returns false when the held session cannot
    /// account for the change; the caller then re-anchors through a fresh present.
    func advanceInline(to remainingText: String, insertedText: String) -> Bool {
        guard var session = inlineSession, case .visible(_, _, let mode) = state, case .inline = mode else {
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
        // Host text under a row is hidden by an opaque band in the field's measured background; with
        // no measurement the ghost stays to rows over blank space, as it always did.
        let canPaintBands = session.hostBackground != nil
        return GhostTextLayout.make(
            GhostTextLayout.Input(
                fullText: session.fullText,
                consumedUTF16: session.consumedUTF16,
                font: session.fontResolution.font,
                anchorTopLeft: CGPoint(x: session.anchorCaretRect.minX, y: session.anchorCaretRect.maxY),
                boxHeight: session.anchorCaretRect.height,
                baselineOffsetFromTop: session.baselineOffsetFromTop,
                linePitch: linePitch(for: geometry),
                wrapBand: wrapBand(for: geometry),
                isRightToLeft: geometry.isRightToLeft,
                allowsMultipleRows: canPaintBands || !geometry.hasTrailingContent,
                keycapWidth: keycapWidth,
                paintsRowBands: canPaintBands && geometry.hasTrailingContent,
                coversCaretRow: !geometry.isCaretAtEndOfLine,
                containerFrame: geometry.elementFrameRect
            )
        )
    }

    /// Vertical distance between the host's lines: measured when the host let us (line APIs, a
    /// character-bounds scan, sibling text runs), else the caret box height. For a TextKit host the
    /// caret box IS the line fragment, so that is exact; for a web engine it is the content box and
    /// can be a pixel short of the line box (Chrome: 15 or 16 for a 16.25 pitch), which matters
    /// only until the field has a second line to measure. A row placed a pixel off beats the card:
    /// measured live, the card at the end of a first line was the single most disliked behavior.
    private func linePitch(for geometry: SuggestionOverlayGeometry) -> CGFloat? {
        if let measured = geometry.hostTextMetrics?.linePitch, measured > 0 {
            return measured
        }
        guard geometry.caretRect.height > 0, geometry.caretQuality != .estimated else {
            return nil
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
            isDarkAppearance: isDarkAppearance,
            caretRowBackground: session.hostBackground.map { Self.bandColor($0.caretLine) },
            continuationBackground: session.hostBackground.map { Self.bandColor($0.nextLine) }
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

    /// A captured pixel as a fill color. The capture is decoded into a device-RGB bitmap and the
    /// panel is composited by the same display, so the device initializer reproduces the pixel.
    private static func bandColor(_ pixel: RGBABitmap.Pixel) -> NSColor {
        NSColor(deviceRed: pixel.red, green: pixel.green, blue: pixel.blue, alpha: 1)
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
            "bands": .stringConvertible(session.layout.rowBands.count),
            "band_rects": .string(
                session.layout.rowBands
                    .map { String(format: "%.1f,%.1f,%.1f,%.1f", $0.rect.minX, $0.rect.minY, $0.rect.width, $0.rect.height) }
                    .joined(separator: ";")
            ),
            "caret_band": .stringConvertible(session.layout.rowBands.contains(where: \.isCaretRow)),
            "truncated": .stringConvertible(session.layout.isTruncated),
            "background_known": .stringConvertible(session.hostBackground != nil),
            "trailing_content": .stringConvertible(session.geometry.hasTrailingContent),
            "row0_pen_x": .stringConvertible(Double(firstRow?.penX ?? 0)),
            "row0_baseline_y": .stringConvertible(Double(firstRow?.baselineY ?? 0)),
            "panel_x": .stringConvertible(Double(panelFrame.minX)),
            "panel_y": .stringConvertible(Double(panelFrame.minY)),
            "panel_w": .stringConvertible(Double(panelFrame.width)),
            "panel_h": .stringConvertible(Double(panelFrame.height)),
            "has_width_sample": .stringConvertible(session.geometry.hostTextMetrics?.sampleWidth != nil),
            "line_pitch": .stringConvertible(Double(session.geometry.hostTextMetrics?.linePitch ?? 0)),
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
                "background_known": .stringConvertible(baselineCalibrator?.cachedBackground(for: geometry.focusedInputIdentityKey) != nil),
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
