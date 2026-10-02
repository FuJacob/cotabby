import AppKit
import SwiftUI

/// One translation drawn under a message.
struct TranslationLabel: Equatable, Identifiable {
    let id: Int
    let text: String
    /// The message it translates, in global points with a top-left origin.
    let messageFrame: CGRect
}

/// Draws translations on screen: labels under incoming messages, and the reply-translation card
/// under the field being typed in.
///
/// Both panels are borderless, non-activating, and click-through (`ignoresMouseEvents`), like the
/// ghost-text panel (`OverlayController`) and the focus debug overlay, so they never take focus or
/// block clicks in the chat app. The incoming panel covers the chat window and draws every label in
/// one SwiftUI view; it is excluded from screen capture because Cotabby captures the window by
/// itself (`SCContentFilter(desktopIndependentWindow:)`), never the composited screen.
@MainActor
final class TranslationOverlayController {
    private var incomingPanel: TranslationPanel?
    private var replyPanel: TranslationPanel?

    // MARK: - Incoming messages

    func showIncoming(_ labels: [TranslationLabel], windowFrame: CGRect) {
        guard !labels.isEmpty else {
            hideIncoming()
            return
        }
        let panel = incomingPanel ?? Self.makePanel()
        incomingPanel = panel
        let cocoaFrame = ScreenSpace.cocoaRect(fromGlobal: windowFrame)
        panel.setFrame(cocoaFrame, display: false)
        panel.contentView = NSHostingView(rootView: IncomingTranslationLabels(labels: labels, windowFrame: windowFrame))
        panel.orderFrontRegardless()
    }

    func hideIncoming() {
        incomingPanel?.orderOut(nil)
    }

    // MARK: - Reply card

    /// Shows `translation` under the field at `fieldFrame` (Cocoa coordinates, as Accessibility
    /// snapshots report them), or above it when the field sits at the bottom of the screen.
    func showReply(translation: String, languageName: String, shortcutLabel: String, below fieldFrame: CGRect) {
        let panel = replyPanel ?? Self.makePanel()
        replyPanel = panel
        let view = NSHostingView(rootView: ReplyTranslationCard(
            translation: translation, languageName: languageName, shortcutLabel: shortcutLabel
        ))
        let width = min(max(fieldFrame.width, 320), 640)
        view.frame.size.width = width
        let height = view.fittingSize.height
        let screen = NSScreen.screens.first { $0.frame.intersects(fieldFrame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? fieldFrame
        var origin = CGPoint(x: fieldFrame.minX, y: fieldFrame.minY - height - 6)
        if origin.y < visible.minY { origin.y = fieldFrame.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        panel.contentView = view
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    func hideReply() {
        replyPanel?.orderOut(nil)
    }

    func hideAll() {
        hideIncoming()
        hideReply()
    }

    private static func makePanel() -> TranslationPanel {
        let panel = TranslationPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }
}

/// Never key or main: the panels must not steal focus from the chat app.
private final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Converts between global display points with a top-left origin (ScreenCaptureKit, Accessibility)
/// and AppKit's bottom-left Cocoa coordinates, across all screens.
enum ScreenSpace {
    @MainActor
    static func cocoaRect(fromGlobal rect: CGRect) -> CGRect {
        let desktop = NSScreen.screens.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !desktop.isNull else { return rect }
        return CGRect(x: rect.minX, y: desktop.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    @MainActor
    static func globalRect(fromCocoa rect: CGRect) -> CGRect {
        cocoaRect(fromGlobal: rect)
    }
}

private struct IncomingTranslationLabels: View {
    let labels: [TranslationLabel]
    let windowFrame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(labels) { label in
                Text(label.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.accentColor.opacity(0.5)))
                    .frame(maxWidth: max(label.messageFrame.width, 220), alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: label.messageFrame.minX - windowFrame.minX,
                            y: label.messageFrame.maxY - windowFrame.minY + 2)
            }
        }
        .frame(width: windowFrame.width, height: windowFrame.height, alignment: .topLeading)
    }
}

private struct ReplyTranslationCard: View {
    let translation: String
    let languageName: String
    let shortcutLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "character.bubble")
                Text(languageName).font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(shortcutLabel) to replace your draft")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(translation)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.accentColor.opacity(0.5)))
        .padding(2)
    }
}
