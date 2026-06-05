import AppKit
import Foundation
import Logging
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

        // Per-app render-mode overrides are not wired yet, so the policy always resolves without a
        // host bundle identifier; thread the focused app's id here when per-app overrides ship.
        let mode = currentRenderModePolicy.mode(
            for: geometry,
            bundleIdentifier: nil
        )

        switch mode {
        case .inline:
            showInline(text: text, geometry: geometry)
        case .mirror(let reason):
            showMirror(text: text, geometry: geometry, reason: reason)
        }

        state = .visible(text: text, geometry: geometry, mode: mode)
    }

    /// Hides the floating panel and records why the overlay is no longer visible.
    func hide(reason: String) {
        panel.orderOut(nil)
        state = .hidden(reason: reason)
    }

    /// Inline ghost text drawn next to the caret. This is the original rendering path; the body
    /// stays unchanged from the pre-mirror behavior aside from being extracted into its own method.
    private func showInline(text: String, geometry: SuggestionOverlayGeometry) {
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
        let layout = GhostSuggestionLayout.make(
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
            opacity: ghostOpacity
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
            maximum: qualityCap
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
            // Tuned per color scheme so the green stays legible in both appearances without dropping
            // below a comfortable contrast floor against typical text-field backgrounds.
            let correctionColor = colorScheme == .dark
                ? Color(red: 0.45, green: 0.85, blue: 0.45)
                : Color(red: 0.15, green: 0.60, blue: 0.20)
            return correctionColor.opacity(opacity)
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

    private var ghostColor: Color {
        let baseColor = customColor
            ?? (
                colorScheme == .dark
                    ? Color(red: 0.85, green: 0.85, blue: 0.85)
                    : Color(red: 0.25, green: 0.25, blue: 0.25)
            )
        return baseColor.opacity(opacity)
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
            Text(layout.suggestionText)
                .font(.system(size: layout.fontSize))
                .foregroundStyle(ghostColor)
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
