import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Owns the tiny non-activating panel that marks supported inputs with a subtle affordance.
/// Unlike the ghost-text overlay, this controller is focus-driven and can anchor either to the
/// caret itself or to the left edge of the active text area.
///
/// Keeping this as a separate controller preserves the architectural split between:
/// supported-field affordances and suggestion-specific UI.
@MainActor
final class ActivationIndicatorController {
    private let verticalGap: CGFloat = 2
    /// Field-edge mode should visually touch the input's outside edge. A gap reads as accidental
    /// padding because the icon is an affordance for the field itself, not for the surrounding UI.
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

    private var lastMode: ActivationIndicatorMode?

    /// Sizes and positions the chosen activation affordance for the current field.
    ///
    /// `caretAnchor` points directly at the insertion point, while `fieldEdgeIcon` places tabby's
    /// icon outside the text area's left edge so the signal stays visible even when caret geometry
    /// is jittery.
    func show(
        mode: ActivationIndicatorMode,
        caretRect: CGRect,
        inputFrameRect: CGRect?
    ) {
        guard mode != .hidden else {
            hide(reason: "Activation indicator hidden because the chosen mode is Hidden.")
            return
        }

        guard !caretRect.isEmpty else {
            hide(reason: "Activation indicator hidden because the caret rect was empty.")
            return
        }

        contentView.rootView = AnyView(view(for: mode))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        let origin: CGPoint
        switch mode {
        case .hidden:
            hide(reason: "Activation indicator hidden because the chosen mode is Hidden.")
            return
        case .caretAnchor:
            origin = caretAnchorOrigin(for: caretRect, contentSize: contentSize)
        case .fieldEdgeIcon:
            origin = fieldEdgeIconOrigin(
                caretRect: caretRect,
                inputFrameRect: inputFrameRect,
                contentSize: contentSize
            )
        }

        let frame = CGRect(origin: origin, size: contentSize).integral
        if lastMode == mode, panel.frame == frame, panel.isVisible {
            return
        }

        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        lastMode = mode
    }

    /// Hides the indicator when tabby is not actively supporting the current field.
    func hide(reason _: String) {
        panel.orderOut(nil)
        lastMode = nil
    }

    @ViewBuilder
    private func view(for mode: ActivationIndicatorMode) -> some View {
        switch mode {
        case .hidden:
            EmptyView()
        case .caretAnchor:
            CaretAnchorIndicatorView()
        case .fieldEdgeIcon:
            FieldEdgeIconIndicatorView()
        }
    }

    /// Centers the caret pointer horizontally on the caret and prefers placing it just below the
    /// current line box. If the caret is too close to the bottom edge of the visible screen,
    /// we fall back above the line instead.
    private func caretAnchorOrigin(for caretRect: CGRect, contentSize: CGSize) -> CGPoint {
        let centeredX = caretRect.midX - (contentSize.width / 2)
        let preferredBelowY = caretRect.minY - contentSize.height - verticalGap

        guard let screen = screen(for: caretRect) else {
            return CGPoint(x: centeredX, y: preferredBelowY)
        }

        let visibleFrame = screen.visibleFrame
        let fallbackAboveY = caretRect.maxY + verticalGap
        let preferredY = preferredBelowY >= visibleFrame.minY + screenInset
            ? preferredBelowY
            : fallbackAboveY

        let clampedX = min(
            max(centeredX, visibleFrame.minX + screenInset),
            visibleFrame.maxX - contentSize.width - screenInset
        )
        let clampedY = min(
            max(preferredY, visibleFrame.minY + screenInset),
            visibleFrame.maxY - contentSize.height - screenInset
        )

        return CGPoint(x: clampedX, y: clampedY)
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

private struct CaretAnchorIndicatorView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var bgColor: Color {
        colorScheme == .dark ? Color(white: 0.18) : Color(white: 0.95)
    }

    var body: some View {
        CaretPointerTriangle(cornerRadius: 1.5)
            .fill(bgColor)
            .frame(width: 8, height: 5)
            .shadow(color: .black.opacity(0.16), radius: 1, y: 1)
            .fixedSize()
    }
}

/// A small upward triangle reads as a pointer to the insertion point when it sits below the line.
/// Rounded corners make it feel softer and visually closer to the ghost keycap styling.
private struct CaretPointerTriangle: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width * 0.2, rect.height * 0.35)
        let apex = CGPoint(x: rect.midX, y: rect.minY)
        let right = CGPoint(x: rect.maxX, y: rect.maxY)
        let left = CGPoint(x: rect.minX, y: rect.maxY)

        func insetPoint(from corner: CGPoint, toward other: CGPoint, by distance: CGFloat) -> CGPoint {
            let dx = other.x - corner.x
            let dy = other.y - corner.y
            let length = max(sqrt(dx * dx + dy * dy), 0.0001)
            return CGPoint(
                x: corner.x + (dx / length) * distance,
                y: corner.y + (dy / length) * distance
            )
        }

        let apexRight = insetPoint(from: apex, toward: right, by: radius)
        let apexLeft = insetPoint(from: apex, toward: left, by: radius)
        let rightTop = insetPoint(from: right, toward: apex, by: radius)
        let rightBottom = insetPoint(from: right, toward: left, by: radius)
        let leftBottom = insetPoint(from: left, toward: right, by: radius)
        let leftTop = insetPoint(from: left, toward: apex, by: radius)

        var path = Path()
        path.move(to: apexRight)
        path.addQuadCurve(to: apexLeft, control: apex)
        path.addLine(to: leftTop)
        path.addQuadCurve(to: leftBottom, control: left)
        path.addLine(to: rightBottom)
        path.addQuadCurve(to: rightTop, control: right)
        path.closeSubpath()
        return path
    }
}
