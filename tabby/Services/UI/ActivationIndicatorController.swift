import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Owns the tiny non-activating panel that marks supported inputs with tabby's icon near
/// the field edge. Unlike the ghost-text overlay, this controller is focus-driven and toggled
/// by a simple boolean.
///
/// Keeping this as a separate controller preserves the architectural split between:
/// supported-field affordances and suggestion-specific UI.
@MainActor
final class ActivationIndicatorController {
    /// Field-edge mode should visually touch the input's outside edge.
    private let fieldEdgeGap: CGFloat = 0
    private let screenInset: CGFloat = 2

    private lazy var contentView: NSHostingView<AnyView> = {
        NSHostingView(rootView: AnyView(EmptyView()))
    }()

    private lazy var panel: ActivationIndicatorPanel = {
        let panel = ActivationIndicatorPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = contentView
        return panel
    }()

    private var isVisible = false

    /// Shows or hides the field-edge tabby icon indicator.
    func show(
        enabled: Bool,
        caretRect: CGRect,
        inputFrameRect: CGRect?
    ) {
        guard enabled else {
            hide(reason: "Activation indicator hidden because it is disabled.")
            return
        }

        guard !caretRect.isEmpty else {
            hide(reason: "Activation indicator hidden because the caret rect was empty.")
            return
        }

        contentView.rootView = AnyView(FieldEdgeIconIndicatorView())
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize
        let origin = fieldEdgeIconOrigin(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            contentSize: contentSize
        )

        let frame = CGRect(origin: origin, size: contentSize).integral
        if isVisible, panel.frame == frame, panel.isVisible {
            return
        }

        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Hides the indicator when tabby is not actively supporting the current field.
    func hide(reason _: String) {
        panel.orderOut(nil)
        isVisible = false
    }

    /// Places tabby's icon just outside the text area's left edge. When the field is flush against
    /// the screen edge we fall back to the right side so the icon stays fully visible.
    private func fieldEdgeIconOrigin(
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        contentSize: CGSize
    ) -> CGPoint {
        let anchorRect = if let inputFrameRect, !inputFrameRect.isEmpty {
            inputFrameRect
        } else {
            caretRect
        }

        let preferredLeftX = anchorRect.minX - contentSize.width - fieldEdgeGap
        let fallbackRightX = anchorRect.maxX + fieldEdgeGap
        let centeredY = anchorRect.midY - (contentSize.height / 2)

        guard let screen = screen(for: anchorRect) else {
            return CGPoint(x: preferredLeftX, y: centeredY)
        }

        let visibleFrame = screen.visibleFrame
        let preferredX = preferredLeftX >= visibleFrame.minX + screenInset
            ? preferredLeftX
            : fallbackRightX

        let clampedX = min(
            max(preferredX, visibleFrame.minX + screenInset),
            visibleFrame.maxX - contentSize.width - screenInset
        )
        let clampedY = min(
            max(centeredY, visibleFrame.minY + screenInset),
            visibleFrame.maxY - contentSize.height - screenInset
        )

        return CGPoint(x: clampedX, y: clampedY)
    }

    /// Chooses the screen that currently contains the given rect's center point.
    private func screen(for rect: CGRect) -> NSScreen? {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)

        if let containingScreen = NSScreen.screens.first(where: {
            $0.visibleFrame.contains(midpoint)
        }) {
            return containingScreen
        }

        return NSScreen.screens.first(where: { $0.frame.intersects(rect) })
    }
}

private final class ActivationIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct FieldEdgeIconIndicatorView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.92)
    }

    private var pawColor: Color {
        colorScheme == .dark ? .white : Color(white: 0.25)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(bgColor)
            Image(systemName: "pawprint.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(pawColor)
        }
        .frame(width: 20, height: 20)
        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        .fixedSize()
    }
}

