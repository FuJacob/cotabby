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
        static let minimumGhostFontSize: CGFloat = 14
        static let maximumGhostFontSize: CGFloat = 24
        static let maximumEstimatedGhostFontSize: CGFloat = 16
        static let fontToLineHeightRatio: CGFloat = 0.78
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

        // Per-app render-mode overrides are not wired yet, so the policy always resolves without a
        // host bundle identifier; thread the focused app's id here when per-app overrides ship.
        let mode = currentRenderModePolicy.mode(
            for: geometry,
            bundleIdentifier: nil
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
            focusSessionKey: geometry.focusedInputIdentityKey
        )
        // The host field's own font, when AX exposed it. Instantiated at the reported size only to
        // read its (scale-invariant) glyph-box ratio; the rendered size comes from the caret height.
        let referenceFieldFont = geometry.resolvedFieldStyle.flatMap(fieldFont(from:))
        let fontSize = resolvedGhostFontSize(
            forCaretHeight: stabilizedCaretHeight,
            caretQuality: geometry.caretQuality,
            fieldFont: referenceFieldFont
        )
        // Render in the field's typeface at the derived size so the ghost reads as a continuation of
        // the host text rather than pasted-on system font. Nil falls back to the system font.
        let renderFont = referenceFieldFont.flatMap { NSFont(name: $0.fontName, size: fontSize) }
        // `nil` when the user disabled the hint or no accept key is bound — in that case the layout
        // drops the keycap and its reserved width so ghost text can use the full line.
        let acceptanceHintLabel = suggestionSettings.acceptanceHintLabel
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
        let showsHint = suggestionSettings.acceptanceHintLabel != nil
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

    /// Mirror-mode rendering. Draws the suggestion inside a Cotabby-owned card anchored to the
    /// input field rectangle (not the caret rect) so unreliable caret geometry does not propagate
    /// into the card position. The card is otherwise visually similar to inline ghost text plus a
    /// backdrop that makes it read as a UI element rather than free-floating text.
    private func showMirror(
        text: String,
        geometry: SuggestionOverlayGeometry,
        reason: CompletionRenderMode.MirrorReason
    ) {
        let acceptanceHintLabel = suggestionSettings.acceptanceHintLabel
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
        fieldFont: NSFont?
    ) -> CGFloat {
        let qualityCap = caretQuality == .estimated
            ? Layout.maximumEstimatedGhostFontSize
            : Layout.maximumGhostFontSize

        let fieldMetrics = fieldFont.map {
            GhostFontMetrics.FieldFontMetrics(
                pointSize: $0.pointSize,
                ascender: $0.ascender,
                descender: $0.descender
            )
        }

        return GhostFontMetrics.pointSize(
            caretHeight: caretHeight,
            fieldMetrics: fieldMetrics,
            fallbackRatio: Layout.fontToLineHeightRatio,
            minimum: Layout.minimumGhostFontSize,
            maximum: qualityCap,
            sizeMultiplier: CGFloat(suggestionSettings.ghostTextSizeMultiplier)
        )
    }

    /// Builds the host field's `NSFont` from a resolved style, or nil when the name is missing or the
    /// font cannot be instantiated. The size is only a reference for metric extraction; the rendered
    /// size is derived from caret height in `resolvedGhostFontSize`.
    private func fieldFont(from style: ResolvedFieldStyle) -> NSFont? {
        guard let name = style.fontName else { return nil }
        return NSFont(name: name, size: style.fontPointSize ?? Layout.minimumGhostFontSize)
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

/// The green used to signal a typo correction. Tuned per color scheme so it stays legible in both
/// appearances without dropping below a comfortable contrast floor against typical text-field
/// backgrounds. Shared by the inline ghost and the mirror card so a correction reads identically in
/// either display mode; the user's custom suggestion color is intentionally bypassed for corrections
/// because semantic communication beats personalization here.
private enum SuggestionCorrectionStyle {
    static func color(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.45, green: 0.85, blue: 0.45)
            : Color(red: 0.15, green: 0.60, blue: 0.20)
    }
}

/// Small SwiftUI view hosted inside the floating AppKit panel.
/// Keeping the rendered content separate from the window controller makes styling easier to evolve
/// without touching the AppKit positioning code.
private struct GhostSuggestionView: View {
    @Environment(\.colorScheme) var colorScheme
    let layout: GhostSuggestionLayout
    let fontSize: CGFloat
    /// The host field's font at the rendered size, or nil to use the system font at `fontSize`.
    let fieldFont: NSFont?
    /// The host field's foreground color mapped to a ghost color, or nil to use the default gray.
    let fieldColor: Color?
    let customColor: Color?
    /// The accept key to print inside the keycap pill, or `nil` when the hint is suppressed. Pairs
    /// with `layout.lines`, where `showsKeycap` is already false on every line when this is `nil`.
    let keycapLabel: String?
    /// User-controlled fade for the suggestion text, in [0.3, 1.0]. Applied only to the ghost text,
    /// not the keycap, so the acceptance hint stays legible at low opacities.
    let opacity: Double
    /// When true, the suggestion is replacing a typo'd word. We render in green to signal that
    /// accepting will swap the user's last word, not extend it. The custom color override is
    /// intentionally bypassed in this mode: semantic communication beats personalization here.
    let isCorrection: Bool

    /// Priority: explicit user override, then the host field's color, then the default gray. The
    /// field color is pre-filtered upstream so invisible extremes already fall back to nil here.
    var ghostColor: Color {
        if isCorrection {
            return SuggestionCorrectionStyle.color(for: colorScheme).opacity(opacity)
        }
        let baseColor = customColor
            ?? fieldColor
            ?? (
                colorScheme == .dark
                    ? Color(red: 0.65, green: 0.65, blue: 0.65)
                    : Color(red: 0.45, green: 0.45, blue: 0.45)
            )
        return baseColor.opacity(opacity)
    }

    /// The host field's typeface when known, otherwise the system font at the derived size.
    private var resolvedFont: Font {
        if let fieldFont {
            return Font(fieldFont as CTFont)
        }
        return .system(size: fontSize)
    }

    var body: some View {
        let alignment: HorizontalAlignment = layout.isRightToLeft ? .trailing : .leading
        VStack(alignment: alignment, spacing: 0) {
            ForEach(layout.lines) { line in
                let showsKeycap = line.showsKeycap && keycapLabel != nil
                HStack(alignment: .firstTextBaseline, spacing: showsKeycap ? 6 : 0) {
                    if layout.isRightToLeft, showsKeycap, let keycapLabel {
                        GhostKeycap(label: keycapLabel)
                    }

                    Text(line.text)
                        .font(resolvedFont)
                        .foregroundStyle(ghostColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)

                    if !layout.isRightToLeft, showsKeycap, let keycapLabel {
                        GhostKeycap(label: keycapLabel)
                    }
                }
                .padding(layout.isRightToLeft ? .trailing : .leading, line.leadingIndent)
                .fixedSize(horizontal: true, vertical: true)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// Visual hint that teaches the user which key accepts the suggestion. The label tracks the user's
/// configured accept keybind, so rebinding away from Tab updates the pill instead of lying about it.
private struct GhostKeycap: View {
    @Environment(\.colorScheme) var colorScheme
    let label: String

    var textColor: Color {
        colorScheme == .dark ? Color(white: 0.65) : Color(white: 0.45)
    }

    var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.95)
    }

    var borderColor: Color {
        colorScheme == .dark ? Color(white: 0.3) : Color(white: 0.8)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(textColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: true)
    }
}

/// Mirror-mode card. Renders the suggestion inside a Cotabby-owned backdrop anchored below the
/// focused field. Unlike `GhostSuggestionView`, this view is single-line by design — the whole
/// reason mirror mode exists is that the host's caret rect is unreliable, so multi-line wrapping
/// would just compound the positioning uncertainty.
///
/// The backdrop and shadow are what make this read as a deliberate UI element instead of a stray
/// floating text label. We do not try to disguise the card as the host editor; Cotypist's product
/// language ("preview") is the right framing here.
private struct MirrorOverlayView: View {
    @Environment(\.colorScheme) var colorScheme
    let layout: MirrorOverlayLayout
    let customColor: Color?
    let keycapLabel: String?
    let opacity: Double
    /// When true, the suggestion replaces a typo'd word; the whole card lights up green to match the
    /// inline ghost, and the next-accept-word highlight is suppressed (the correction is one unit).
    let isCorrection: Bool

    private var ghostColor: Color {
        if isCorrection {
            return SuggestionCorrectionStyle.color(for: colorScheme).opacity(opacity)
        }
        let baseColor = customColor
            ?? (
                colorScheme == .dark
                    ? Color(red: 0.85, green: 0.85, blue: 0.85)
                    : Color(red: 0.25, green: 0.25, blue: 0.25)
            )
        return baseColor.opacity(opacity)
    }

    /// The next-accept word renders at full strength so it reads as "this is what Tab takes next."
    /// The user's custom suggestion color (if set) is honored at full opacity; otherwise the primary
    /// label color keeps strong contrast against the card backdrop in both appearances.
    private var highlightColor: Color {
        customColor ?? .primary
    }

    /// The suggestion as one attributed run: the highlighted prefix (the next accept-word) is drawn
    /// full-strength and semibold so it "lights up" as the word being completed, while the rest keeps
    /// the muted ghost color. Building one `AttributedString` instead of two `Text`s keeps the card on
    /// a single line and lets tail-truncation treat the whole suggestion as one unit.
    private var styledSuggestion: AttributedString {
        var attributed = AttributedString(layout.suggestionText)
        attributed.font = .system(size: layout.fontSize)
        attributed.foregroundColor = ghostColor

        // A correction replaces the whole word, so the entire run stays green; the next-accept-word
        // highlight (which marks where Tab stops mid-completion) does not apply to a correction.
        guard !isCorrection else { return attributed }

        let prefix = layout.highlightedPrefix
        guard !prefix.isEmpty, layout.suggestionText.hasPrefix(prefix) else {
            return attributed
        }
        let characters = attributed.characters
        let highlightEnd = characters.index(characters.startIndex, offsetBy: prefix.count)
        let highlightRange = characters.startIndex..<highlightEnd
        attributed[highlightRange].foregroundColor = highlightColor
        attributed[highlightRange].font = .system(size: layout.fontSize, weight: .semibold)
        return attributed
    }

    private var backdropColor: Color {
        colorScheme == .dark
            ? Color(white: 0.16).opacity(0.96)
            : Color(white: 0.98).opacity(0.96)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color(white: 0.28) : Color(white: 0.82)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(styledSuggestion)
                .lineLimit(1)
                .truncationMode(.tail)

            if let keycapLabel {
                GhostKeycap(label: keycapLabel)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(backdropColor)
                .shadow(color: .black.opacity(0.12), radius: 6, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(borderColor, lineWidth: 0.5)
        )
        // The panel itself is sized by MirrorOverlayLayout to the card dimensions, so we don't
        // need fixedSize here — the view fills the panel exactly.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Right-to-left hosts get the SwiftUI environment flip so the keycap lands on the leading
        // side of the suggestion text, mirroring how RTL languages read.
        .environment(\.layoutDirection, layout.isRightToLeft ? .rightToLeft : .leftToRight)
    }
}
