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
        /// "policy" (font metrics rule) or "calibrated" (measured from the host's pixels).
        var baselineSource: String
        var layout: GhostTextLayout
    }

    private var inlineSession: InlineSession?
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
    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry) {
        guard !text.isEmpty else {
            hide(reason: "Overlay not shown because the suggestion was empty.")
            return
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
            if !showInline(text: text, geometry: geometry) {
                mode = .mirror(reason: .inlineLayoutUnavailable)
                showMirror(text: text, geometry: geometry, reason: .inlineLayoutUnavailable)
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

    /// Presents `text` anchored at the geometry's caret box as a fresh inline session. Returns false
    /// when no honest inline layout exists for this text and geometry.
    private func showInline(text: String, geometry: SuggestionOverlayGeometry) -> Bool {
        let renderer: GhostBaselinePolicy.HostRenderer = geometry.isWebContentField ? .webEngine : .textKit
        let fontResolution = resolveFont(for: geometry, renderer: renderer)
        let policyOffset = GhostBaselinePolicy.baselineOffsetFromTop(
            font: fontResolution.font,
            boxHeight: geometry.caretRect.height,
            renderer: renderer
        )
        let calibration = calibrationRequest(for: geometry, resolution: fontResolution, policyOffset: policyOffset)
        let cachedOffset = calibration.flatMap { baselineCalibrator?.cachedOffset(for: $0.key) }
        var session = InlineSession(
            fullText: text,
            consumedUTF16: 0,
            anchorCaretRect: geometry.caretRect,
            geometry: geometry,
            fontResolution: fontResolution,
            baselineOffsetFromTop: cachedOffset ?? policyOffset,
            baselineSource: cachedOffset == nil ? "policy" : "calibrated",
            layout: GhostTextLayout(
                rows: [],
                font: fontResolution.font,
                boxHeight: 0,
                baselineOffsetFromTop: 0,
                keycapFrame: nil,
                contentBounds: .zero
            )
        )
        guard let layout = makeLayout(for: session) else {
            logInlineDeclined(geometry: geometry, fontResolution: fontResolution)
            return false
        }
        session.layout = layout
        inlineSession = session
        renderInline(session)
        if cachedOffset == nil || calibration?.matchTypeface == true, let calibration {
            startCalibration(calibration, for: geometry)
        }
        return true
    }

    /// The host's face by report or measurement; for a web field the host never named, a face the
    /// host's own pixels matched earlier in this field replaces the system stand-in.
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
        return Self.applyingMatchedTypeface(
            resolution,
            name: baselineCalibrator?.cachedTypeface(for: typefaceKey(for: geometry, font: resolution.font)),
            isWebContentField: geometry.isWebContentField
        )
    }

    private static func applyingMatchedTypeface(
        _ resolution: GhostFontResolver.Resolution,
        name: String?,
        isWebContentField: Bool
    ) -> GhostFontResolver.Resolution {
        guard isWebContentField, resolution.provenance.isFallbackFace, let name,
              let matched = GhostFontResolver.font(named: name, size: resolution.font.pointSize)
        else {
            return resolution
        }
        return GhostFontResolver.Resolution(font: matched, provenance: .pixelMatched, widthAgreement: 1)
    }

    private func typefaceKey(for geometry: SuggestionOverlayGeometry, font: NSFont) -> HostBaselineCalibrator.TypefaceKey {
        HostBaselineCalibrator.TypefaceKey(
            focusedInputIdentityKey: geometry.focusedInputIdentityKey,
            fontPointSize: Int(font.pointSize.rounded())
        )
    }

    /// Starts measuring the host's baseline for the line the caret is on, while the model is still
    /// generating, so the first ghost on that line already sits on the measured baseline.
    func prepareInlinePresentation(for context: FocusedInputContext) {
        guard baselineCalibrator != nil, context.isWebContentField else { return }
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
            isWebContentField: true,
            elementFrameRect: context.elementFrameRect,
            lineTextBeforeCaret: HostLineText.tail(of: context.precedingText)
        )
        let fontResolution = resolveFont(for: geometry, renderer: .webEngine)
        let policyOffset = GhostBaselinePolicy.baselineOffsetFromTop(
            font: fontResolution.font,
            boxHeight: context.caretRect.height,
            renderer: .webEngine
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
        guard baselineCalibrator != nil, geometry.isWebContentField else { return nil }
        let font = resolution.font
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
            matchTypeface: resolution.provenance.isFallbackFace
        )
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
            if abs(session.baselineOffsetFromTop - calibration.baselineOffset) > 0.01 {
                session.baselineOffsetFromTop = calibration.baselineOffset
                session.baselineSource = "calibrated"
                changed = true
            }
            let rematched = Self.applyingMatchedTypeface(
                session.fontResolution, name: calibration.typefaceName, isWebContentField: geometry.isWebContentField
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
                allowsMultipleRows: !geometry.hasTrailingContent,
                keycapWidth: keycapWidth
            )
        )
    }

    /// Vertical distance between the host's lines. Only a measured value is trusted for a second
    /// row; a TextKit host without measured lines still has a reliable one: its caret box IS the
    /// line fragment, so consecutive lines are exactly one box apart.
    private func linePitch(for geometry: SuggestionOverlayGeometry) -> CGFloat? {
        if let measured = geometry.hostTextMetrics?.linePitch, measured > 0 {
            return measured
        }
        guard !geometry.isWebContentField, geometry.caretQuality == .exact || geometry.caretQuality == .derived else {
            return nil
        }
        return geometry.caretRect.height
    }

    /// The horizontal band ghost rows may occupy (see `GhostWrapBandPolicy`).
    private func wrapBand(for geometry: SuggestionOverlayGeometry) -> ClosedRange<CGFloat>? {
        GhostWrapBandPolicy.band(
            GhostWrapBandPolicy.Input(
                caretRect: geometry.caretRect,
                elementFrame: geometry.elementFrameRect,
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
            "caret_top": .stringConvertible(Double(session.anchorCaretRect.maxY)),
            "caret_h": .stringConvertible(Double(session.anchorCaretRect.height)),
            "caret_quality": .string(session.geometry.caretQuality.label),
            "web_field": .stringConvertible(session.geometry.isWebContentField),
            "consumed_utf16": .stringConvertible(session.consumedUTF16),
            "rows": .stringConvertible(session.layout.rows.count),
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

    private func logInlineDeclined(geometry: SuggestionOverlayGeometry, fontResolution: GhostFontResolver.Resolution) {
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        CotabbyLogger.suggestion.debug(
            "Inline ghost declined; showing the card",
            metadata: [
                "stage": .string("overlay-inline-declined"),
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
