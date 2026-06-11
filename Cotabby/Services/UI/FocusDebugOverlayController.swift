import AppKit
import Foundation
import SwiftUI

/// Gated behind `-cotabby-debug`. Shows focused-input geometry near the caret and renders a
/// bottom-edge status panel for focus polling diagnostics and the screenshot/OCR visual-context
/// pipeline.
///
/// The controller is UI-only. It observes already-published app state instead of asking
/// `FocusTracker` or `VisualContextCoordinator` for data directly, which keeps the service layer
/// headless and testable.
@MainActor
final class FocusDebugOverlayController {
    static let launchArgument = CotabbyDebugOptions.launchArgument

    static var isEnabled: Bool {
        CotabbyDebugOptions.isEnabled
    }

    private lazy var caretPanel: NSPanel = makePanel()
    private lazy var framePanel: NSPanel = makePanel()
    private lazy var bottomStatusPanel: NSPanel = makePanel(draggable: true)

    /// User-dragged origin for the bottom panel. `nil` means use the default centered position.
    private var bottomPanelDraggedOrigin: CGPoint?

    /// The last origin we set programmatically, used to detect genuine user drags.
    private var bottomPanelProgrammaticOrigin: CGPoint?

    private var latestCaretRect: CGRect?
    private var latestVisualContextStatus: VisualContextStatus = .idle
    private var latestVisualContextExcerptCharacterCount: Int?
    private var latestPollEvent: FocusPollingEvent?

    func update(for snapshot: FocusSnapshot) {
        guard let context = snapshot.context else {
            hideFocusGeometry()
            return
        }

        latestCaretRect = context.caretRect
        showCaretIndicator(context: context)
        showFrameOutline(context: context)
    }

    /// Mirrors visual-context lifecycle state into the bottom debug panel.
    ///
    /// We show metadata only, not the OCR text or summary. The raw prompt block remains the source
    /// of truth for sensitive text debugging, and it is already gated behind `-cotabby-debug`.
    func updateVisualContext(status: VisualContextStatus, excerpt: String?) {
        latestVisualContextStatus = status
        latestVisualContextExcerptCharacterCount = excerpt?.count
        renderBottomStatusPanel()
    }

    /// Mirrors focus polling diagnostics into the bottom status panel.
    ///
    /// Polling diagnostics replace the old AXObserver pulse. This keeps focus debugging tied to
    /// the single source of truth that now drives snapshots.
    func updateFocusPolling(event: FocusPollingEvent) {
        latestPollEvent = event
        renderBottomStatusPanel()
    }

    func hide() {
        hideFocusGeometry()
        latestPollEvent = nil
        latestVisualContextStatus = .idle
        latestVisualContextExcerptCharacterCount = nil
        bottomStatusPanel.orderOut(nil)
    }

    // MARK: - Caret indicator

    /// Short build stamp (executable modification time) shown in the caret badge so a debugging
    /// screenshot proves which build produced it. Stale-binary confusion has burned whole field
    /// iterations: a fix gets pushed, the relaunch silently runs yesterday's product, and the
    /// "still broken" report describes code that no longer exists.
    private static let buildStamp: String = {
        guard let url = Bundle.main.executableURL,
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                as? Date
        else {
            return "build ?"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return "build \(formatter.string(from: modified))"
    }()

    private func showCaretIndicator(context: FocusedInputSnapshot) {
        let color = indicatorColor(for: context.caretSource)
        let contentView = NSHostingView(rootView: CaretDebugView(
            source: context.caretSource,
            role: context.role,
            buildStamp: Self.buildStamp,
            caretHeight: context.caretRect.height,
            color: color
        ))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        // Anchor the line at the caret position with the label floating above.
        let origin = CGPoint(
            x: context.caretRect.minX - 1,
            y: context.caretRect.minY
        )

        caretPanel.contentView = contentView
        caretPanel.setFrame(CGRect(origin: origin, size: contentSize).integral, display: true)
        caretPanel.orderFrontRegardless()
    }

    // MARK: - Input frame outline

    private func showFrameOutline(context: FocusedInputSnapshot) {
        guard let inputFrame = context.inputFrameRect, !inputFrame.isEmpty else {
            framePanel.orderOut(nil)
            return
        }

        let borderWidth: CGFloat = 1
        let inset = borderWidth / 2
        let contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.cyan.opacity(0.6), lineWidth: borderWidth)
                .padding(inset)
        )

        let expanded = inputFrame.insetBy(dx: -2, dy: -2)
        framePanel.contentView = contentView
        framePanel.setFrame(expanded.integral, display: true)
        framePanel.orderFrontRegardless()
    }

    // MARK: - Bottom status panel

    private func renderBottomStatusPanel() {
        guard shouldShowBottomStatusPanel else {
            bottomStatusPanel.orderOut(nil)
            return
        }

        // Detect genuine user drags by comparing against the last programmatic origin.
        if bottomStatusPanel.isVisible,
           let programmatic = bottomPanelProgrammaticOrigin {
            let current = bottomStatusPanel.frame.origin
            if current != programmatic {
                bottomPanelDraggedOrigin = current
            }
        }

        let screenFrame = targetScreenVisibleFrame()
        let maxWidth = min(screenFrame.width - 32, 620)
        let contentView = NSHostingView(rootView: BottomDebugStatusView(
            visualContextStatus: latestVisualContextStatus,
            excerptCharacterCount: latestVisualContextExcerptCharacterCount,
            pollEvent: latestPollEvent,
            maxWidth: maxWidth
        ))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize

        let origin: CGPoint
        if let dragged = bottomPanelDraggedOrigin {
            origin = dragged
        } else {
            origin = CGPoint(
                x: screenFrame.midX - (contentSize.width / 2),
                y: screenFrame.minY + 14
            )
        }

        let frame = CGRect(origin: origin, size: contentSize).integral
        bottomStatusPanel.contentView = contentView
        bottomStatusPanel.setFrame(frame, display: true)
        bottomPanelProgrammaticOrigin = frame.origin
        bottomStatusPanel.orderFrontRegardless()
    }

    private var shouldShowBottomStatusPanel: Bool {
        latestVisualContextStatus != .idle || latestPollEvent != nil
    }

    // MARK: - Helpers

    private func hideFocusGeometry() {
        latestCaretRect = nil
        caretPanel.orderOut(nil)
        framePanel.orderOut(nil)
    }

    private func makePanel(draggable: Bool = false) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = !draggable
        panel.isMovableByWindowBackground = draggable
        panel.hasShadow = false
        // Above activation indicator and ghost text so it is always visible during debugging.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    private func indicatorColor(for source: String) -> Color {
        if source.contains("exact") { return .green }
        if source.contains("derived") { return .yellow }
        return .red
    }

    private func targetScreenVisibleFrame() -> CGRect {
        if let latestCaretRect,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(latestCaretRect) }) {
            return screen.visibleFrame
        }

        return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    }
}

// MARK: - SwiftUI views

private struct CaretDebugView: View {
    let source: String
    let role: String
    let buildStamp: String
    let caretHeight: CGFloat
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(source) | \(role) | \(buildStamp)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.85))
                )

            Rectangle()
                .fill(color)
                .frame(width: 2, height: caretHeight)
        }
        .fixedSize()
    }
}

private struct BottomDebugStatusView: View {
    let visualContextStatus: VisualContextStatus
    let excerptCharacterCount: Int?
    let pollEvent: FocusPollingEvent?
    let maxWidth: CGFloat

    private var stages: [VisualContextDebugStage] {
        VisualContextDebugStage.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Visual context")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)

                Text(statusSummary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                ForEach(stages) { stage in
                    VisualContextStagePill(
                        title: stage.title,
                        state: stageState(for: stage)
                    )
                }
            }

            HStack(spacing: 10) {
                Text(remainingSummary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)

                if let excerptCharacterCount {
                    Text("context \(excerptCharacterCount)c")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }

            if let pollEvent {
                Divider()
                    .overlay(Color.white.opacity(0.16))

                HStack(spacing: 7) {
                    Circle()
                        .fill(pollEvent.didChangeFocusedInput ? Color.green : Color.cyan)
                        .frame(width: 7, height: 7)

                    Text("Poll \(pollEvent.sequence)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.cyan)

                    Text(pollEvent.changeSummary)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(pollEvent.didChangeFocusedInput ? .green : .white.opacity(0.72))
                        .lineLimit(1)

                    Text("focusSeq \(pollEvent.focusChangeSequence)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)

                    Text("\(pollEvent.applicationName) / \(pollEvent.capabilitySummary)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: maxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusSummary: String {
        switch visualContextStatus {
        case .idle:
            return "idle"
        case .capturing:
            return "capturing screenshot"
        case .extractingText:
            return "running OCR"
        case .ready:
            return "ready"
        case .unavailable:
            return "unavailable"
        case .failed:
            return "failed"
        }
    }

    private var statusColor: Color {
        switch visualContextStatus {
        case .ready:
            return .green
        case .unavailable, .failed:
            return .red
        case .idle:
            return .white.opacity(0.5)
        case .capturing, .extractingText:
            return .yellow
        }
    }

    private var remainingSummary: String {
        switch visualContextStatus {
        case .idle:
            return "Waiting for focused text input."
        case .ready:
            return "All stages complete."
        case .unavailable(let reason), .failed(let reason):
            return reason
        case .capturing, .extractingText:
            let remaining = stages
                .filter { stageState(for: $0) == .pending }
                .map(\.title)
            return remaining.isEmpty ? "No stages left." : "Left: \(remaining.joined(separator: " -> "))"
        }
    }

    private func stageState(for stage: VisualContextDebugStage) -> VisualContextStageDisplayState {
        switch visualContextStatus {
        case .idle:
            return .pending
        case .capturing:
            return stage == .capture ? .active : .pending
        case .extractingText:
            if stage == .capture { return .completed }
            return stage == .ocr ? .active : .pending
        case .ready:
            return .completed
        case .unavailable, .failed:
            return .blocked
        }
    }
}

private struct VisualContextStagePill: View {
    let title: String
    let state: VisualContextStageDisplayState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.color)
                .frame(width: 6, height: 6)

            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(state.textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(state.backgroundColor)
        )
    }
}

private enum VisualContextDebugStage: CaseIterable, Identifiable {
    case capture
    case ocr
    case inject

    var id: Self { self }

    var title: String {
        switch self {
        case .capture:
            return "Capture"
        case .ocr:
            return "OCR"
        case .inject:
            return "Inject"
        }
    }
}

private enum VisualContextStageDisplayState {
    case pending
    case active
    case completed
    case blocked

    var color: Color {
        switch self {
        case .pending:
            return .white.opacity(0.35)
        case .active:
            return .yellow
        case .completed:
            return .green
        case .blocked:
            return .red
        }
    }

    var textColor: Color {
        switch self {
        case .pending:
            return .white.opacity(0.52)
        case .active, .completed, .blocked:
            return .white
        }
    }

    var backgroundColor: Color {
        switch self {
        case .pending:
            return .white.opacity(0.08)
        case .active:
            return .yellow.opacity(0.28)
        case .completed:
            return .green.opacity(0.22)
        case .blocked:
            return .red.opacity(0.25)
        }
    }
}
