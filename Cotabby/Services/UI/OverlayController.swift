import AppKit
import Foundation
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

    /// Bundle identifier of the currently focused host app, supplied by the coordinator each time
    /// a suggestion is presented. The policy uses this to look up per-app overrides. Nil in tests
    /// or when the focus pipeline could not identify the host.
    private var currentBundleIdentifier: String?

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

    /// Coordinator hook that updates the bundle identifier used by per-app overrides. Phase 1
    /// callers do not need this (policy is `.auto` with no overrides); Phase 2 will wire it through
    /// the presenter so per-app settings take effect immediately when the focused app changes.
    func setCurrentBundleIdentifier(_ bundleIdentifier: String?) {
        currentBundleIdentifier = bundleIdentifier
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

        let mode = currentRenderModePolicy.mode(
            for: geometry,
            bundleIdentifier: currentBundleIdentifier
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
        let stabilizedCaretHeight = ghostFontStabilizer.stabilizedCaretHeight(
            geometry.caretRect.height,
            focusSessionKey: geometry.focusChangeSequence
        )
        let fontSize = resolvedGhostFontSize(
            forCaretHeight: stabilizedCaretHeight,
            caretQuality: geometry.caretQuality
        )
        // `nil` when the user disabled the hint or no accept key is bound — in that case the layout
        // drops the keycap and its reserved width so ghost text can use the full line.
        let acceptanceHintLabel = suggestionSettings.acceptanceHintLabel
        let layout = GhostSuggestionLayout.make(
            text: text,
            geometry: geometry,
            fontSize: fontSize,
            visibleFrame: targetScreenVisibleFrame(for: geometry.caretRect),
            showsAcceptanceHint: acceptanceHintLabel != nil
        )
        let customGhostColor = SuggestionTextColorCodec.color(
            fromHex: suggestionSettings.customSuggestionTextColorHex
        )
        let ghostOpacity = suggestionSettings.ghostTextOpacity

        let rootView = GhostSuggestionView(
            layout: layout,
            fontSize: fontSize,
            customColor: customGhostColor,
            keycapLabel: acceptanceHintLabel,
            opacity: ghostOpacity
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

        panel.setFrame(layout.panelFrame, display: true)
        panel.orderFrontRegardless()
    }

    /// Exact and derived caret rects usually reflect the real text line height, so they may scale
    /// up in larger editors. Estimated rects are much less trustworthy because some apps only
    /// expose the full field frame; the extra ceiling prevents one bad estimate from rendering
    /// comically oversized ghost text. `caretHeight` is already floored to the per-session minimum
    /// by `ghostFontStabilizer`, so this only applies the static floor and quality ceilings.
    private func resolvedGhostFontSize(
        forCaretHeight caretHeight: CGFloat,
        caretQuality: CaretGeometryQuality
    ) -> CGFloat {
        let proposedSize = max(
            Layout.minimumGhostFontSize,
            caretHeight * Layout.fontToLineHeightRatio
        )
        let qualityCap = caretQuality == .estimated
            ? Layout.maximumEstimatedGhostFontSize
            : Layout.maximumGhostFontSize

        return min(proposedSize, qualityCap)
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
    let customColor: Color?
    /// The accept key to print inside the keycap pill, or `nil` when the hint is suppressed. Pairs
    /// with `layout.lines`, where `showsKeycap` is already false on every line when this is `nil`.
    let keycapLabel: String?
    /// User-controlled fade for the suggestion text, in [0.3, 1.0]. Applied only to the ghost text,
    /// not the keycap, so the acceptance hint stays legible at low opacities.
    let opacity: Double

    var ghostColor: Color {
        let baseColor = customColor
            ?? (
                colorScheme == .dark
                    ? Color(red: 0.65, green: 0.65, blue: 0.65)
                    : Color(red: 0.45, green: 0.45, blue: 0.45)
            )
        return baseColor.opacity(opacity)
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
                        .font(.system(size: fontSize))
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
