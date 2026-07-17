import CoreGraphics
import Foundation

/// Adapts pixel-sourced Claude Code input into the suggestion pipeline's focus value.
///
/// Including the ScreenCaptureKit window id in the element identity keeps two terminal windows in
/// the same process from sharing an autocomplete session or cached completion.
enum TuiFocusAdapter {
    static func adapt(
        reading: TuiContextReader.PromptReading,
        capture: TerminalWindowCapture,
        caretRect: CGRect,
        inputFrameRect: CGRect,
        sourceRevision: UInt64,
        focusChangeSequence: UInt64 = 0
    ) -> FocusedInputSnapshot {
        FocusedInputSnapshot(
            applicationName: capture.descriptor.applicationName,
            bundleIdentifier: capture.descriptor.bundleIdentifier,
            processIdentifier: capture.descriptor.pid,
            elementIdentifier: "terminal-tui-claude-\(capture.descriptor.pid)-\(capture.descriptor.windowID)",
            role: TerminalInputRole.claudeCodeTUI.rawValue,
            subrole: "OCR",
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            caretSource: "ClaudeCodeTuiOCR",
            caretQuality: .estimated,
            observedCharWidth: TerminalGeometryResolver.defaultCellMetrics.cellWidth,
            precedingText: reading.promptText,
            trailingText: "",
            selection: NSRange(location: reading.estimatedCursorOffset, length: 0),
            isSecure: false,
            isIntegratedTerminal: TerminalAppDetector.hostsEmbeddedTerminal(
                bundleIdentifier: capture.descriptor.bundleIdentifier
            ),
            focusChangeSequence: focusChangeSequence,
            resolvedFieldStyle: ResolvedFieldStyle(
                fontName: "Menlo-Regular",
                fontPointSize: 13,
                colorHex: nil
            ),
            windowTitle: capture.descriptor.title,
            sourceRevision: sourceRevision
        )
    }
}
