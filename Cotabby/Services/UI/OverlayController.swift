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
    private var hostingView: NSHostingView<AnyView>?

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

        let fontSize = resolvedGhostFontSize(
            for: geometry.caretRect,
            caretQuality: geometry.caretQuality
        )
        let layout = GhostSuggestionLayout.make(
            text: text,
            geometry: geometry,
            fontSize: fontSize,
            visibleFrame: targetScreenVisibleFrame(for: geometry.caretRect)
        )
        let customGhostColor = SuggestionTextColorCodec.color(
            fromHex: suggestionSettings.customSuggestionTextColorHex
        )
        let rootView = AnyView(GhostSuggestionView(
            layout: layout,
            fontSize: fontSize,
            customColor: customGhostColor
        ))
        let contentView: NSHostingView<AnyView>
        if let existing = hostingView {
            existing.rootView = rootView
            contentView = existing
        } else {
            let fresh = NSHostingView(rootView: rootView)
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

    /// Shows a compact multiline draft preview. Compose output is intentionally not drawn as inline
    /// ghost text because accepting a full paragraph needs a more deliberate visual affordance.
    func showComposePreview(_ text: String, geometry: SuggestionOverlayGeometry) {
        let previewText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previewText.isEmpty else {
            hide(reason: "Overlay not shown because the Compose draft was empty.")
            return
        }

        let contentView: NSHostingView<AnyView>
        let rootView = AnyView(ComposePreviewView(text: previewText))
        if let existing = hostingView {
            existing.rootView = rootView
            contentView = existing
        } else {
            let fresh = NSHostingView(rootView: rootView)
            hostingView = fresh
            panel.contentView = fresh
            contentView = fresh
        }
        contentView.layoutSubtreeIfNeeded()

        let visibleFrame = targetScreenVisibleFrame(for: geometry.caretRect)
        let contentSize = contentView.fittingSize
        let width = min(max(contentSize.width, 260), min(420, visibleFrame.width - 32))
        let height = min(max(contentSize.height, 96), min(260, visibleFrame.height - 32))
        let originX = min(
            max(geometry.caretRect.maxX + 8, visibleFrame.minX + 16),
            visibleFrame.maxX - width - 16
        )
        let preferredOriginY = geometry.caretRect.minY - height - 10
        let originY = preferredOriginY >= visibleFrame.minY + 16
            ? preferredOriginY
            : min(geometry.caretRect.maxY + 10, visibleFrame.maxY - height - 16)

        panel.setFrame(
            CGRect(x: originX, y: originY, width: width, height: height).integral,
            display: true
        )
        panel.orderFrontRegardless()
        state = .composePreview(text: previewText, geometry: geometry)
    }

    /// Shows the small "Drafting…" pill near the caret while Compose waits on its first token.
    /// Sized tighter than the preview box so it reads as a status chip, not content.
    func showComposeProgress(_ label: String, geometry: SuggestionOverlayGeometry) {
        let contentView: NSHostingView<AnyView>
        let rootView = AnyView(ComposeProgressView(label: label))
        if let existing = hostingView {
            existing.rootView = rootView
            contentView = existing
        } else {
            let fresh = NSHostingView(rootView: rootView)
            hostingView = fresh
            panel.contentView = fresh
            contentView = fresh
        }
        contentView.layoutSubtreeIfNeeded()

        let visibleFrame = targetScreenVisibleFrame(for: geometry.caretRect)
        let contentSize = contentView.fittingSize
        let width = min(max(contentSize.width, 96), min(220, visibleFrame.width - 32))
        let height = min(max(contentSize.height, 28), 48)
        let originX = min(
            max(geometry.caretRect.maxX + 8, visibleFrame.minX + 16),
            visibleFrame.maxX - width - 16
        )
        let preferredOriginY = geometry.caretRect.minY - height - 8
        let originY = preferredOriginY >= visibleFrame.minY + 16
            ? preferredOriginY
            : min(geometry.caretRect.maxY + 8, visibleFrame.maxY - height - 16)

        panel.setFrame(
            CGRect(x: originX, y: originY, width: width, height: height).integral,
            display: true
        )
        panel.orderFrontRegardless()
        state = .composeProgress(label: label, geometry: geometry)
    }

    /// Hides the floating panel and records why the overlay is no longer visible.
    func hide(reason: String) {
        panel.orderOut(nil)
        state = .hidden(reason: reason)
    }

    /// Exact and derived caret rects usually reflect the real text line height, so they may scale
    /// up in larger editors. Estimated rects are much less trustworthy because some apps only
    /// expose the full field frame; the extra ceiling prevents one bad estimate from rendering
    /// comically oversized ghost text.
    private func resolvedGhostFontSize(
        for caretRect: CGRect,
        caretQuality: CaretGeometryQuality
    ) -> CGFloat {
        let proposedSize = max(
            Layout.minimumGhostFontSize,
            caretRect.height * Layout.fontToLineHeightRatio
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
                HStack(alignment: .firstTextBaseline, spacing: line.showsKeycap ? 6 : 0) {
                    if layout.isRightToLeft && line.showsKeycap {
                        GhostTabKeycap()
                    }

                    Text(line.text)
                        .font(.system(size: fontSize))
                        .foregroundStyle(ghostColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)

                    if !layout.isRightToLeft && line.showsKeycap {
                        GhostTabKeycap()
                    }
                }
                .padding(layout.isRightToLeft ? .trailing : .leading, line.leadingIndent)
                .fixedSize(horizontal: true, vertical: true)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct ComposePreviewView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Compose Draft")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text("tab to type")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(8)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 380, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Compact "Drafting…" status pill shown while Compose waits on its first streamed token.
private struct ComposeProgressView: View {
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)

            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// Visual hint that teaches the user which key accepts the suggestion.
private struct GhostTabKeycap: View {
    @Environment(\.colorScheme) var colorScheme

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
        Text("tab")
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
