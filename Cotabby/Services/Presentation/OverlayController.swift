import AppKit
import Foundation
import Logging
import QuartzCore
import SwiftUI

/// File overview:
/// Owns the non-activating floating panel that renders ghost text near the caret. AppKit window
/// behavior stays isolated here so the coordinator only has to reason about overlay state.
///
/// This separation matters because overlay bugs are often windowing bugs, not state-machine bugs.
/// By keeping the panel lifecycle here, `SuggestionCoordinator` can stay focused on suggestion logic.
@MainActor
final class OverlayController: SuggestionOverlayControlling {
    private enum Layout {
        // The ghost-size floor and ceiling now live in Settings (Appearance -> Ghost Text Size
        // Limits); their shipped defaults are in `SuggestionSettingsStore`. Only the caps for paths
        // whose caret rect is *not* a real measurement stay here, because those guard against bad
        // geometry rather than expressing a user preference.
        static let maximumEstimatedGhostFontSize: CGFloat = 16
        /// Ceiling for a size the *host itself* reported, which only applies on the synthetic-caret
        /// path. It is deliberately looser than both caret-derived caps: those guard against a bad
        /// caret *rect*, a risk that does not exist for a point size read straight out of the host's
        /// own text attributes. It stays bounded so a nonsense AX value still cannot paint a
        /// full-screen suggestion. 32pt covers zoomed body text (Word at 161% renders 16pt as ~26pt)
        /// and ordinary headings.
        static let maximumHostReportedFontSize: CGFloat = 32
        static let fontToLineHeightRatio: CGFloat = 0.78
        /// Size used only to instantiate a host font so its metrics can be read. The glyph-box
        /// ratio derived from it is scale-invariant, so the value is arbitrary — it never
        /// reaches the screen and must not be confused with a rendered size.
        static let metricProbeFontSize: CGFloat = 12
    }

    var onStateChange: ((OverlayState) -> Void)?

    private let suggestionSettings: SuggestionSettingsModel

    /// Optional injection seam for tests. When set, `currentRenderModePolicy` returns this directly
    /// instead of building one from live settings. Production code leaves this nil.
    private let renderModePolicyOverride: CompletionRenderModePolicy?

    /// Built from the live `mirrorPreference` setting at call time rather than cached. The struct
    /// is tiny (one enum + an empty dict in Phase 2) so per-show allocation cost is negligible,
    /// and the read-through model means the user's Settings/menu-bar toggle takes effect on the
    /// very next presentation without any subscription bookkeeping.
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

    /// Reused across overlay updates to avoid allocating a new SwiftUI hosting view on every
    /// tab-per-word cycle. Only the rootView is swapped, which triggers a lightweight diff
    /// instead of a full view rebuild + layout pass.
    ///
    /// Inline and mirror modes keep separate hosting views because their root view types differ
    /// (`GhostSuggestionView` vs `MirrorOverlayView`). Sharing one hosting view via `AnyView` would
    /// defeat SwiftUI's type-aware diffing.
    private var inlineHostingView: NSHostingView<GhostSuggestionView>?
    private var mirrorHostingView: NSHostingView<MirrorOverlayView>?

    /// Per-focus-session floor for caret-derived font size. Caret height flickers between the real
    /// line height and the coarse field-height fallback from poll to poll; stabilizing keeps ghost
    /// text from ballooning when the fallback wins. See `GhostFontSizeStabilizer`.
    private var ghostFontStabilizer = GhostFontSizeStabilizer()

    /// The font and size the inline ghost was last rendered with, captured so `advanceInline` can
    /// measure the handed-off prefix in exactly the rendered typeface. Nil until the first inline show.
    private var lastInlineRenderFont: NSFont?
    private var lastInlineFontSize: CGFloat?

    /// Signature of the last ghost-font resolution written to the log. Inline ghost text re-renders
    /// on every keystroke, so logging each render would bury the signal; this emits one line per
    /// *distinct* outcome instead. See `logGhostFontResolution`.
    private var lastLoggedFontSignature: String?

    /// Same idea for the placement line: inline ghost text re-renders on every keystroke, and the
    /// caret X changes each time, so the signature excludes every value that tracks the caret —
    /// including the panel's own origin, which follows it in the inline path. What is worth one line
    /// per change is the *shape* of the placement, not the fact that the caret moved.
    private var lastLoggedPlacementSignature: String?

    /// `"<bundle id>|<font name>"` pairs already handed to `HostFontRegistry`, so a font the host
    /// bundle does not contain is looked up once rather than on every render. Grows only with the
    /// number of distinct unresolvable fonts actually encountered, which is small.
    private var requestedHostFonts: Set<String> = []

    init(
        suggestionSettings: SuggestionSettingsModel,
        renderModePolicyOverride: CompletionRenderModePolicy? = nil
    ) {
        self.suggestionSettings = suggestionSettings
        self.renderModePolicyOverride = renderModePolicyOverride
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
        // We want ghost text to feel like immediate ink at the caret, not like a floating window
        // being presented by AppKit. Disabling window animation removes the subtle pop/spring
        // effect that can happen when the panel first appears.
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }()

    /// Sizes and positions the overlay using the render mode the policy picks for this geometry.
    /// Each mode is responsible for its own layout math and SwiftUI view; this entry point just
    /// routes and records the resulting state.
    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry) {
        guard !text.isEmpty else {
            hide(reason: "Overlay not shown because the suggestion was empty.")
            return
        }

        // Decide on the fade using the panel state captured *before* `state` is reassigned below, so
        // the animation plays only on a genuine appearance. A reposition and a streamed-token
        // extension re-enter this path while the panel stays visible; restarting the opacity ramp on
        // either would make stable ghost text flicker. Note `advanceInline` calls `showInline`
        // directly and never routes through here, so it is exempt by construction without needing
        // the `overlayWasVisible` guard.
        let fadesIn = SuggestionFadeInPolicy.shouldFadeIn(
            isEnabled: suggestionSettings.fadeInSuggestions,
            overlayWasVisible: state.isVisible,
            reduceMotionEnabled: reduceMotionEnabled
        )

        let mode = currentRenderModePolicy.mode(
            for: geometry,
            bundleIdentifier: geometry.bundleIdentifier
        )

        // Start fully transparent so the panel's first composited frame is invisible. Setting alpha
        // before the show paths call `orderFront` avoids a one-frame flash at full opacity. The else
        // branch resets the model value directly (off the animator), which cancels any stale mid-ramp
        // animation left paused by an order-out so a non-fading show can't resume semi-transparent.
        if fadesIn {
            panel.alphaValue = 0
        } else {
            panel.alphaValue = 1
        }

        switch mode {
        case .inline:
            showInline(text: text, geometry: geometry)
        case .mirror(let reason):
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
        state = .hidden(reason: reason)
    }

    /// Mirrors the system Accessibility "Reduce Motion" preference. Read live so flipping it in
    /// System Settings suppresses the fade on the next suggestion without relaunching Cotabby.
    private var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Ramps the panel from fully transparent to opaque over the user's configured fade duration.
    /// Driven through the AppKit animator proxy, which animates independently of
    /// `panel.animationBehavior` (kept `.none` so AppKit's own order-in spring stays off). Starting a
    /// fresh ramp supersedes any still-running one, so a rapid hide/show cannot strand the panel
    /// mid-fade. The duration is read live (the model keeps it clamped to a sane band), so the
    /// Settings speed slider takes effect on the very next suggestion.
    private func fadeInPanel() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = suggestionSettings.fadeInDurationSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Inline ghost text drawn next to the caret. This is the original rendering path; the body
    /// stays unchanged from the pre-mirror behavior aside from being extracted into its own method.
    ///
    /// `precomputedLayout` lets a caller that already laid this text out for the same geometry, font,
    /// and size (currently `advanceInline`, which builds one for its single-line guard) reuse it
    /// instead of paying a second Core Text layout pass on every word accept.
    private func showInline(
        text: String,
        geometry: SuggestionOverlayGeometry,
        precomputedLayout: GhostSuggestionLayout? = nil
    ) {
        // Key the stabilizer on the field's identity rather than `focusChangeSequence`. The polling
        // signature in `FocusTracker` bumps `focusChangeSequence` whenever the field's frame
        // changes, which includes the common "input grew taller as text wrapped" case. Using the
        // identity key keeps the per-session caret-height minimum alive across that growth and
        // still resets on genuine field switches.
        let stabilizedCaretHeight = ghostFontStabilizer.stabilizedCaretHeight(
            geometry.caretRect.height,
            // Everything but `.estimated` measured real text-range geometry, so it reports the
            // host's true line box and must be trusted even when it grew mid-session — the user
            // raising the font size or the zoom does exactly that without changing fields.
            isPreciseMeasurement: geometry.caretQuality != .estimated,
            focusSessionKey: geometry.focusedInputIdentityKey
        )
        // The host field's own font, when AX exposed it. Instantiated at the reported size only to
        // read its (scale-invariant) glyph-box ratio; the rendered size comes from the caret height.
        let referenceFieldFont = geometry.resolvedFieldStyle.flatMap {
            fieldFont(from: $0, bundleIdentifier: geometry.bundleIdentifier)
        }
        // Read the reported size straight off the style rather than off `referenceFieldFont`, which
        // is nil whenever the typeface itself could not be instantiated. The two facts are
        // independent: a host can name a font we cannot load while still reporting a usable size.
        let hostReportedPointSize = geometry.resolvedFieldStyle?.fontPointSize
        let fontSize = resolvedGhostFontSize(
            forCaretHeight: stabilizedCaretHeight,
            caretQuality: geometry.caretQuality,
            fieldFont: referenceFieldFont,
            hostReportedPointSize: hostReportedPointSize
        )
        logGhostFontResolution(
            geometry: geometry,
            stabilizedCaretHeight: stabilizedCaretHeight,
            hostReportedPointSize: hostReportedPointSize,
            referenceFieldFont: referenceFieldFont,
            fontSize: fontSize
        )
        // Render in the field's typeface at the derived size so the ghost reads as a continuation of
        // the host text rather than pasted-on system font. Nil falls back to the system font.
        let renderFont = referenceFieldFont.flatMap { NSFont(name: $0.fontName, size: fontSize) }
        // `nil` when the user disabled the hint or no accept key is bound — in that case the layout
        // drops the keycap and its reserved width so ghost text can use the full line.
        let acceptanceHintLabel = suggestionSettings.acceptanceHintLabel(
            forBundleIdentifier: geometry.bundleIdentifier
        )
        let layout = precomputedLayout ?? GhostSuggestionLayout.make(
            text: text,
            geometry: geometry,
            fontSize: fontSize,
            visibleFrame: targetScreenVisibleFrame(for: geometry.caretRect),
            showsAcceptanceHint: acceptanceHintLabel != nil,
            font: renderFont
        )
        let customGhostColor = SuggestionTextColorCodec.color(
            fromHex: suggestionSettings.customSuggestionTextColorHex
        )
        let ghostOpacity = suggestionSettings.ghostTextOpacity

        let rootView = GhostSuggestionView(
            layout: layout,
            fontSize: fontSize,
            fieldFont: renderFont,
            fieldColor: fieldGhostColor(from: geometry.resolvedFieldStyle),
            customColor: customGhostColor,
            keycapLabel: acceptanceHintLabel,
            opacity: ghostOpacity,
            isCorrection: geometry.isCorrection
        )

        let contentView: NSHostingView<GhostSuggestionView>
        if let existing = inlineHostingView {
            existing.rootView = rootView
            contentView = existing
        } else {
            let fresh = NSHostingView(rootView: rootView)
            inlineHostingView = fresh
            contentView = fresh
        }

        // Mirror mode and inline mode share the same panel but use different SwiftUI root view
        // types. Switching modes mid-suggestion requires re-attaching the panel's contentView; an
        // identity check skips the re-attach when we're already on the right view.
        if panel.contentView !== contentView {
            panel.contentView = contentView
        }

        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        let frame = layout.panelFrame(for: contentSize, caretRect: geometry.caretRect)

        // Last-resort guard: AppKit raises on a non-finite frame. The AX ingest boundary already
        // rejects NaN/Inf rects, so reaching here means the layout math produced one; skip the show
        // rather than crash on the hottest path.
        guard AXHelper.rectHasFiniteComponents(frame) else {
            CotabbyLogger.suggestion.warning("Skipped inline overlay: computed a non-finite frame")
            return
        }
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()

        logGhostPlacement(
            caretRect: geometry.caretRect,
            panelFrame: frame.integral,
            contentSize: contentSize,
            layout: layout,
            renderFont: renderFont,
            fontSize: fontSize
        )

        // Capture exactly what this inline render used, so a subsequent `advanceInline` slides the
        // panel by the prefix width measured in the same typeface and size.
        lastInlineFontSize = fontSize
        lastInlineRenderFont = renderFont
    }

    /// Advances a visible single-line inline ghost to `remainingText` by sliding the panel right by
    /// the caret's travel for `insertedText`. This is the "perfectly still" path for word-by-word
    /// acceptance and type-through: it reads the held overlay state (not a fresh AX caret), so it
    /// cannot jitter against AX noise.
    /// Returns `false` when the held overlay is not a single-line, LTR, inline ghost this can safely
    /// slide; the caller then falls back to a caret-anchored present.
    func advanceInline(to remainingText: String, insertedText: String) -> Bool {
        guard case let .visible(beforeText, geometry, mode) = state,
              case .inline = mode,
              !geometry.isRightToLeft,
              !remainingText.isEmpty,
              remainingText != beforeText,
              let fontSize = lastInlineFontSize
        else {
            return false
        }

        let renderFont = lastInlineRenderFont ?? NSFont.systemFont(ofSize: fontSize)
        // Trusted-geometry hosts get the slide measured in the field's own font: that is the
        // caret's true travel, so the anchor stays aligned with the post-publish AX caret and the
        // stability gate never has to issue a delayed corrective nudge. The ghost render font is
        // floored at 14pt for legibility, so its width of the same text overshoots a 12pt host by
        // ~15% per accepted word; that error used to accumulate in the anchor until the gate
        // snapped the tail sideways with no input in flight. The cost is a few points of tail
        // shift at the accept keystroke itself (the ghost glyphs are wider than the host's), which
        // lands exactly when the text visibly changes anyway. Untrusted/web geometry keeps the
        // pixel-identical ghost-width slide: its anchors are approximate either way, and observed
        // char-width hosts already correct through their own machinery.
        let shift: CGFloat
        if geometry.caretQuality == .exact || geometry.caretQuality == .derived,
           let hostAdvance = InsertedTextAdvance.width(
               of: insertedText,
               observedCharWidth: geometry.observedCharWidth,
               style: geometry.resolvedFieldStyle
           ) {
            shift = hostAdvance
        } else {
            shift = GhostSuggestionLayout.renderedWidth(of: beforeText, font: renderFont)
                - GhostSuggestionLayout.renderedWidth(of: remainingText, font: renderFont)
        }
        // A non-positive or non-finite shift means the tail did not shrink as expected; re-anchor.
        guard shift.isFinite, shift > 0 else {
            return false
        }

        let advancedGeometry = geometry.withCaretRect(
            geometry.caretRect.offsetBy(dx: shift, dy: 0)
        )

        // The exact-width slide is only valid while both the old and new tails fit on one line.
        // Multi-line layout anchors at the field edge, not the caret, so a fresh re-anchor is needed
        // (e.g. the shrinking first-line budget makes the tail start wrapping).
        let showsHint = suggestionSettings.acceptanceHintLabel(
            forBundleIdentifier: geometry.bundleIdentifier
        ) != nil
        let beforeLayout = GhostSuggestionLayout.make(
            text: beforeText,
            geometry: geometry,
            fontSize: fontSize,
            visibleFrame: targetScreenVisibleFrame(for: geometry.caretRect),
            showsAcceptanceHint: showsHint,
            font: renderFont
        )
        let afterLayout = GhostSuggestionLayout.make(
            text: remainingText,
            geometry: advancedGeometry,
            fontSize: fontSize,
            visibleFrame: targetScreenVisibleFrame(for: advancedGeometry.caretRect),
            showsAcceptanceHint: showsHint,
            font: renderFont
        )
        guard beforeLayout.lines.count == 1, afterLayout.lines.count == 1 else {
            return false
        }

        // Render with the already-validated `afterLayout` (no third Core Text pass) and update state
        // directly. The overlay is inline (guarded above) and the caret only shifted horizontally, so
        // the render mode cannot change; setting `.inline` keeps `OverlayState` coherent for the accept
        // and stability gates.
        showInline(text: remainingText, geometry: advancedGeometry, precomputedLayout: afterLayout)
        state = .visible(text: remainingText, geometry: advancedGeometry, mode: .inline)
        return true
    }

    /// Mirror-mode rendering. Draws the suggestion inside a Cotabby-owned card anchored beneath the
    /// best available text line. Estimated geometry remains too weak for inline glyphs, but its
    /// vertical line box keeps the popup beside the visible text instead of below the field chrome.
    /// The card is otherwise visually similar to inline ghost text plus a backdrop that makes it
    /// read as a UI element rather than free-floating text.
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
        let ghostOpacity = suggestionSettings.ghostTextOpacity

        let rootView = MirrorOverlayView(
            layout: layout,
            customColor: customGhostColor,
            keycapLabel: acceptanceHintLabel,
            opacity: ghostOpacity,
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
    }

    /// Exact and derived caret rects usually reflect the real text line height, so they may scale
    /// up in larger editors. Estimated rects are much less trustworthy because some apps only
    /// expose the full field frame; the extra ceiling prevents one bad estimate from rendering
    /// comically oversized ghost text. `caretHeight` is already floored to the per-session minimum
    /// by `ghostFontStabilizer`, so this only applies the static floor and quality ceilings.
    private func resolvedGhostFontSize(
        forCaretHeight caretHeight: CGFloat,
        caretQuality: CaretGeometryQuality,
        fieldFont: NSFont?,
        hostReportedPointSize: CGFloat?
    ) -> CGFloat {
        // The user's ceiling is an absolute upper bound. The built-in caps only *tighten* it further
        // on paths whose caret rect is not a real measurement, so lowering the ceiling always takes
        // effect while raising it never loosens an untrustworthy estimate.
        let userCeiling = CGFloat(suggestionSettings.ghostFontSizeCeiling)
        let userFloor = CGFloat(suggestionSettings.ghostFontSizeFloor)
        let qualityCap = caretQuality == .estimated
            ? min(Layout.maximumEstimatedGhostFontSize, userCeiling)
            : userCeiling

        let fieldMetrics = fieldFont.map {
            GhostFontMetrics.FieldFontMetrics(
                pointSize: $0.pointSize,
                ascender: $0.ascender,
                descender: $0.descender
            )
        }

        return GhostFontMetrics.pointSize(
            caretHeight: caretHeight,
            // Only `.estimated` comes from the AXFrame fallback, whose caret height is a fixed
            // system-font constant rather than a measurement. `.layoutEstimated` is excluded on
            // purpose: it re-derives the caret from a real text layout, so its height is meaningful.
            caretHeightIsSynthetic: caretQuality == .estimated,
            fieldMetrics: fieldMetrics,
            hostReportedPointSize: hostReportedPointSize,
            fallbackRatio: Layout.fontToLineHeightRatio,
            minimum: userFloor,
            maximum: qualityCap,
            syntheticCaretMaximum: min(Layout.maximumHostReportedFontSize, userCeiling),
            sizeMultiplier: CGFloat(suggestionSettings.ghostTextSizeMultiplier)
        )
    }

    /// Records how ghost-text font and size were resolved for the current field.
    ///
    /// This subsystem previously logged nothing, which made "the ghost text looks wrong in app X"
    /// impossible to triage from logs alone: every input to the decision — what the host reported,
    /// which caret branch produced the height, whether the typeface actually loaded — was invisible.
    /// The fields below are exactly what is needed to tell a *host-reporting* problem (no font name,
    /// no point size) from a *caret-geometry* problem (`caret_quality=estimated`, synthetic height)
    /// from a *font-loading* problem (name present, `render_font_resolved=false`).
    ///
    /// Deduplicated by signature because inline ghost text re-renders on every keystroke; one line
    /// per distinct outcome keeps the stream readable. Logged at `.debug`, so it costs nothing in
    /// the default configuration — swift-log skips the autoclosed metadata below the level floor.
    private func logGhostFontResolution(
        geometry: SuggestionOverlayGeometry,
        stabilizedCaretHeight: CGFloat,
        hostReportedPointSize: CGFloat?,
        referenceFieldFont: NSFont?,
        fontSize: CGFloat
    ) {
        // Every inline render reaches this; bail before building the signature so the default,
        // non-debug configuration pays nothing for a diagnostic it will never emit.
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        let style = geometry.resolvedFieldStyle
        let signature = [
            geometry.bundleIdentifier ?? "-",
            style?.fontName ?? "-",
            hostReportedPointSize.map { String(format: "%.1f", $0) } ?? "-",
            geometry.caretQuality.label,
            String(format: "%.1f", stabilizedCaretHeight),
            String(format: "%.1f", fontSize),
            referenceFieldFont?.fontName ?? "-"
        ].joined(separator: "|")

        guard signature != lastLoggedFontSignature else { return }
        lastLoggedFontSignature = signature

        CotabbyLogger.suggestion.debug(
            "Resolved ghost text font",
            metadata: [
                "bundle_id": .string(geometry.bundleIdentifier ?? "unknown"),
                "host_font_name": .string(style?.fontName ?? "none"),
                "host_font_point_size": .string(
                    hostReportedPointSize.map { String(format: "%.2f", $0) } ?? "none"
                ),
                "caret_quality": .string(geometry.caretQuality.label),
                "caret_height": .string(String(format: "%.2f", stabilizedCaretHeight)),
                // True when caret height was fabricated from a fixed system-font constant rather
                // than measured, in which case the host-reported size drives sizing instead.
                "caret_height_synthetic": .stringConvertible(geometry.caretQuality == .estimated),
                "render_font_resolved": .stringConvertible(referenceFieldFont != nil),
                "render_font_name": .string(referenceFieldFont?.fontName ?? "system-fallback"),
                "ghost_font_size": .string(String(format: "%.2f", fontSize))
            ]
        )
    }

    /// Records where the ghost panel actually landed relative to the caret, in enough detail to
    /// compute the baseline error without guessing at SwiftUI's rendered metrics.
    ///
    /// The placement math assumes the rendered line box is `fontSize * lineHeightMultiplier`, but
    /// the panel is actually sized by SwiftUI's `fittingSize`. When those disagree the ghost drifts
    /// vertically, and nothing in the logs previously showed the discrepancy. `content_height` is
    /// the truth; `layout_line_height` is the assumption — comparing the two is the whole point.
    ///
    /// `baseline_delta` is the number that matters: ghost text baseline minus host text baseline,
    /// in points, positive meaning the ghost sits high. It is derived from the render font's own
    /// descent rather than an approximation, so it can be read directly as the visible error.
    private func logGhostPlacement(
        caretRect: CGRect,
        panelFrame: CGRect,
        contentSize: CGSize,
        layout: GhostSuggestionLayout,
        renderFont: NSFont?,
        fontSize: CGFloat
    ) {
        // Same reasoning as `logGhostFontResolution`: skip the font metrics and signature work
        // entirely unless this line can actually be emitted.
        guard CotabbyLogger.suggestion.logLevel <= .debug else { return }
        let font = renderFont ?? NSFont.systemFont(ofSize: fontSize)
        // Text sits on its baseline, which is `descent` above the bottom of its own line box.
        let ghostDescent = -font.descender
        let ghostBaselineY = panelFrame.minY + ghostDescent
        // The host's line box is the caret rect; its text baseline sits a proportional descent up
        // from that box's bottom. Scaling the render font's descent by the box ratio approximates
        // the host's own descent without needing the host's true point size, which Word misreports.
        let hostDescent = ghostDescent * (caretRect.height / max(contentSize.height, 1))
        let hostBaselineY = caretRect.minY + hostDescent

        // Whether the panel actually anchored to the host's measured text margin. Read from the
        // layout's own anchor decision, not from whether edges were measured at all: a single-line
        // suggestion anchors at the caret even when a margin exists, so "measured" and "used"
        // differ, and only "used" answers whether ghost text followed the document margin.
        let usedContentEdge = layout.panelAnchoredToHostContentEdge

        let signature = [
            String(format: "%.0f", caretRect.height),
            String(format: "%.0f", contentSize.height),
            String(layout.lines.count),
            String(usedContentEdge)
        ].joined(separator: "|")
        guard signature != lastLoggedPlacementSignature else { return }
        lastLoggedPlacementSignature = signature

        CotabbyLogger.suggestion.debug(
            "Ghost overlay placement",
            metadata: [
                "caret_y": .string(String(format: "%.2f", caretRect.minY)),
                "caret_height": .string(String(format: "%.2f", caretRect.height)),
                "caret_x": .string(String(format: "%.2f", caretRect.maxX)),
                "panel_y": .string(String(format: "%.2f", panelFrame.minY)),
                "panel_x": .string(String(format: "%.2f", panelFrame.minX)),
                // Gap between the caret and where ghost text starts drawing.
                "caret_to_panel_gap": .string(String(format: "%.2f", panelFrame.minX - caretRect.maxX)),
                // The measured height SwiftUI produced versus the height the math assumed.
                "content_height": .string(String(format: "%.2f", contentSize.height)),
                "layout_line_height": .string(String(format: "%.2f", layout.lineHeight)),
                "line_count": .stringConvertible(layout.lines.count),
                "font_size": .string(String(format: "%.2f", fontSize)),
                "font_natural_line_height": .string(
                    String(format: "%.2f", ceil(font.ascender - font.descender + font.leading))
                ),
                "baseline_delta": .string(String(format: "%.2f", ghostBaselineY - hostBaselineY)),
                "used_host_content_edge": .stringConvertible(usedContentEdge)
            ]
        )
    }

    /// Builds the host field's `NSFont` from a resolved style, or nil when the name is missing or the
    /// font cannot be instantiated. The size is only a reference for metric extraction; the rendered
    /// size is derived from caret height in `resolvedGhostFontSize`.
    ///
    /// When the name does not resolve, this asks `HostFontRegistry` to look for the typeface inside
    /// the host app's own bundle and returns nil for *this* render. Hosts that ship private fonts
    /// (Word's Aptos and Calibri live in its bundle and are installed nowhere on the system) would
    /// otherwise render ghost text in the system font forever. Registration is deliberately not
    /// awaited: it does disk I/O that must not block a render, so the current frame uses the
    /// fallback font and the next one — the overlay redraws continuously through a suggestion —
    /// picks up the now-resolvable font. One frame of fallback is invisible next to generation
    /// latency, and the alternative is stalling the main actor on the hot path.
    private func fieldFont(from style: ResolvedFieldStyle, bundleIdentifier: String?) -> NSFont? {
        guard let name = style.fontName else { return nil }
        if let font = NSFont(name: name, size: style.fontPointSize ?? Layout.metricProbeFontSize) {
            return font
        }
        guard let bundleIdentifier else { return nil }
        // Ask at most once per (host, font) pair. `showInline` runs on every keystroke, so without
        // this a typeface that genuinely is not in the host's bundle — the common case for most
        // apps — would spawn a throwaway Task per render forever. The registry itself is cheap to
        // re-enter, but the Task allocation and actor hop are not free on the hot path.
        let requestKey = "\(bundleIdentifier)|\(name)"
        guard requestedHostFonts.insert(requestKey).inserted else { return nil }
        Task { [weak self] in
            let registered = await HostFontRegistry.shared.ensureFontAvailable(
                named: name,
                bundleIdentifier: bundleIdentifier
            )
            guard registered else { return }
            self?.redrawInlineAfterFontRegistration(fontName: name)
        }
        return nil
    }

    /// Re-renders a visible inline suggestion once a host font finishes registering.
    ///
    /// Without this, "the next render picks it up" is only true while something else is still
    /// causing renders. A suggestion that arrived complete — no streaming, no further keystrokes —
    /// is drawn once, in the fallback font, and stays that way until an unrelated later suggestion
    /// happens to redraw it. Re-showing here is cheap and idempotent: `showInline` recomputes from
    /// the same text and geometry, and the fade is owned by `showSuggestion`, so nothing re-animates.
    ///
    /// Guarded on the font actually being resolvable now, so a registration that reported success
    /// but left the name unusable cannot cause a pointless redraw loop.
    private func redrawInlineAfterFontRegistration(fontName: String) {
        guard case .visible(let text, let geometry, let mode) = state,
              mode == .inline,
              geometry.resolvedFieldStyle?.fontName == fontName,
              NSFont(name: fontName, size: Layout.metricProbeFontSize) != nil
        else {
            return
        }

        showInline(text: text, geometry: geometry)
    }

    /// Maps the host field's foreground color to a ghost color, or nil to fall back to the default
    /// gray. Near-white / near-black extremes are treated as untrustworthy (some browsers report the
    /// page background as the text color) and fall back, so ghost text never renders invisibly.
    private func fieldGhostColor(from style: ResolvedFieldStyle?) -> Color? {
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

        return Color(nsColor: nsColor)
    }

    private func targetScreenVisibleFrame(for caretRect: CGRect) -> CGRect {
        let midpoint = CGPoint(x: caretRect.midX, y: caretRect.midY)

        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) }) {
            return screen.visibleFrame
        }

        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(caretRect) }) {
            return screen.visibleFrame
        }

        return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
