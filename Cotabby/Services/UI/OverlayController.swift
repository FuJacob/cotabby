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

    private(set) var state: OverlayState = .hidden(reason: "Overlay idle.") {
        didSet {
            onStateChange?(state)
        }
    }

    /// Reused across overlay updates to avoid allocating a new SwiftUI hosting view on every
    /// tab-per-word cycle. Only the rootView is swapped, which triggers a lightweight diff
    /// instead of a full view rebuild + layout pass.
    private var hostingView: NSHostingView<GhostSuggestionView>?

    /// Per-focus-session floor for caret-derived font size. Caret height flickers between the real
    /// line height and the coarse field-height fallback from poll to poll; stabilizing keeps ghost
    /// text from ballooning when the fallback wins. See `GhostFontSizeStabilizer`.
    private var ghostFontStabilizer = GhostFontSizeStabilizer()

    init(suggestionSettings: SuggestionSettingsModel) {
        self.suggestionSettings = suggestionSettings
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

    /// Sizes and positions the overlay next to the reported caret bounds for the current field.
    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry) {
        guard !text.isEmpty else {
            hide(reason: "Overlay not shown because the suggestion was empty.")
            return
        }

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
        let contentView: NSHostingView<GhostSuggestionView>
        if let existing = hostingView {
            existing.rootView = GhostSuggestionView(
                layout: layout,
                fontSize: fontSize,
                customColor: customGhostColor,
                keycapLabel: acceptanceHintLabel
            )
            contentView = existing
        } else {
            let fresh = NSHostingView(
                rootView: GhostSuggestionView(
                    layout: layout,
                    fontSize: fontSize,
                    customColor: customGhostColor,
                    keycapLabel: acceptanceHintLabel
                )
            )
            hostingView = fresh
            panel.contentView = fresh
            contentView = fresh
        }
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        let frame = layout.panelFrame(for: contentSize, caretRect: geometry.caretRect)

        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()
        state = .visible(text: text, geometry: geometry)
    }

    /// Hides the floating panel and records why the overlay is no longer visible.
    func hide(reason: String) {
        panel.orderOut(nil)
        state = .hidden(reason: reason)
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

    var ghostColor: Color {
        customColor
            ?? (
                colorScheme == .dark
                    ? Color(red: 0.65, green: 0.65, blue: 0.65)
                    : Color(red: 0.45, green: 0.45, blue: 0.45)
            )
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
