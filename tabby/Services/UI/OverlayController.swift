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
        // A non-activating panel lets Tabby draw UI near the caret without stealing focus
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
    func showSuggestion(_ text: String, at caretRect: CGRect, caretQuality: CaretGeometryQuality, inputFrameRect: CGRect?) {
        guard !text.isEmpty else {
            hide(reason: "Overlay not shown because the suggestion was empty.")
            return
        }

        let fontSize = resolvedGhostFontSize(for: caretRect, caretQuality: caretQuality)
        let customGhostColor = SuggestionTextColorCodec.color(
            fromHex: suggestionSettings.customSuggestionTextColorHex
        )
        let (inlineText, overflowText) = splitTextForWrapping(
            text: text,
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            fontSize: fontSize
        )

        let viewIndent: CGFloat
        let panelOriginX: CGFloat
        let containerWidth: CGFloat?
        
        if overflowText != nil, let frameRect = inputFrameRect {
            panelOriginX = frameRect.minX
            viewIndent = max(0, caretRect.maxX + 6 - frameRect.minX)
            containerWidth = frameRect.width
        } else {
            panelOriginX = caretRect.maxX + 6
            viewIndent = 0
            containerWidth = nil
        }

        let contentView: NSHostingView<GhostSuggestionView>
        if let existing = hostingView {
            existing.rootView = GhostSuggestionView(
                inlineText: inlineText,
                overflowText: overflowText,
                fontSize: fontSize,
                viewIndent: viewIndent,
                containerWidth: containerWidth,
                customColor: customGhostColor
            )
            contentView = existing
        } else {
            let fresh = NSHostingView(
                rootView: GhostSuggestionView(
                    inlineText: inlineText,
                    overflowText: overflowText,
                    fontSize: fontSize,
                    viewIndent: viewIndent,
                    containerWidth: containerWidth,
                    customColor: customGhostColor
                )
            )
            hostingView = fresh
            panel.contentView = fresh
            contentView = fresh
        }
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        // Vertically center the ghost text within the caret rect. 
        // When there are multiple lines, we want the FIRST line to center around the caret's midY.
        let originY: CGFloat
        if overflowText != nil {
            // In AppKit (bottom-up), the top Y is `origin.y + height`.
            // We want the top of the first line to be `caretRect.midY + caretRect.height / 2`.
            let topY = caretRect.midY + caretRect.height / 2
            originY = topY - contentSize.height
        } else {
            originY = caretRect.midY - contentSize.height / 2
        }

        let origin = CGPoint(
            x: panelOriginX,
            y: originY
        )
        let frame = CGRect(origin: origin, size: contentSize)

        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()
        state = .visible(text: text, caretRect: caretRect, caretQuality: caretQuality, inputFrameRect: inputFrameRect)
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

    /// Splits text into the portion that fits on the same line as the caret, and the overflow.
    private func splitTextForWrapping(
        text: String,
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        fontSize: CGFloat
    ) -> (inlineText: String, overflowText: String?) {
        guard let inputFrameRect = inputFrameRect else {
            return (text, nil)
        }
        
        // Tab keycap takes ~40 points; we reserve 10 points for safe margin.
        let availableWidth = max(0, inputFrameRect.maxX - (caretRect.maxX + 6) - 10)
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize)
        ]
        
        let fullWidth = (text as NSString).size(withAttributes: attrs).width
        if fullWidth <= availableWidth {
            return (text, nil)
        }
        
        var lastFitIndex = text.startIndex
        for index in text.indices {
            let substring = text[text.startIndex..<index]
            let width = (String(substring) as NSString).size(withAttributes: attrs).width
            if width > availableWidth {
                break
            }
            if substring.last?.isWhitespace == true {
                lastFitIndex = index
            }
        }
        
        // If not even the first word fits, break at the first space or take the whole text.
        if lastFitIndex == text.startIndex {
            if let firstSpace = text.firstIndex(where: { $0.isWhitespace }) {
                lastFitIndex = firstSpace
            } else {
                lastFitIndex = text.endIndex
            }
        }
        
        let inlineText = String(text[text.startIndex..<lastFitIndex])
        var overflowTextStr = String(text[lastFitIndex..<text.endIndex])
        
        // Trim leading spaces from the overflow text so the wrapped line is flush to the edge
        while overflowTextStr.first?.isWhitespace == true {
            overflowTextStr.removeFirst()
        }
        
        let overflowText = overflowTextStr.isEmpty ? nil : overflowTextStr
        return (inlineText.isEmpty ? text : inlineText, overflowText)
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
    let inlineText: String
    let overflowText: String?
    let fontSize: CGFloat
    let viewIndent: CGFloat
    let containerWidth: CGFloat?
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
        if let overflow = overflowText {
            VStack(alignment: .leading, spacing: 2) {
                Text(inlineText)
                    .font(.system(size: fontSize))
                    .foregroundStyle(ghostColor)
                    .lineLimit(1)
                    .padding(.leading, viewIndent)
                
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(overflow)
                        .font(.system(size: fontSize))
                        .foregroundStyle(ghostColor)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    GhostTabKeycap()
                }
            }
            .frame(maxWidth: containerWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(inlineText)
                    .font(.system(size: fontSize))
                    .foregroundStyle(ghostColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: true)

                GhostTabKeycap()
            }
            .fixedSize(horizontal: true, vertical: true)
        }
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
