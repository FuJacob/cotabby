import Foundation
import Logging

/// Resolves shell-hook buffers to visible prompt geometry without polluting the IPC service.
///
/// The socket service owns trusted text/session state; this coordinator owns screenshots and OCR.
/// Keeping those boundaries separate means shell autocomplete still receives exact context when
/// Screen Recording is unavailable, but the overlay stays hidden until geometry is trustworthy.
@MainActor
final class ShellPromptGeometryCoordinator {
    typealias CaptureProvider = @MainActor (
        TerminalFocusSnapshot,
        Int32
    ) async throws -> TerminalWindowCapture

    var onGeometryResolved: ((TerminalFocusSnapshot) -> Void)?

    /// Coalesces a fast first burst before the prompt anchor exists. Vision requests cannot be
    /// cancelled once dispatched, so delaying dispatch avoids one full OCR job per keystroke.
    private static let captureDebounceNanoseconds: UInt64 = 120_000_000

    private let extractor: any ScreenTextExtracting
    private let captureProvider: CaptureProvider
    private let latestSnapshotProvider: @MainActor (TerminalSessionIdentity) -> TerminalFocusSnapshot?
    private let isEnabled: @MainActor () -> Bool
    private let logger = Logger(label: "com.cotabby.terminal-shell-geometry")
    private var anchors: [TerminalSessionIdentity: TerminalPromptAnchor] = [:]
    private var captureTasks: [TerminalSessionIdentity: Task<Void, Never>] = [:]
    private var previousBuffers: [TerminalSessionIdentity: String] = [:]

    init(
        extractor: any ScreenTextExtracting,
        captureProvider: @escaping CaptureProvider,
        latestSnapshotProvider: @escaping @MainActor (TerminalSessionIdentity) -> TerminalFocusSnapshot?,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        self.extractor = extractor
        self.captureProvider = captureProvider
        self.latestSnapshotProvider = latestSnapshotProvider
        self.isEnabled = isEnabled
    }

    /// Returns geometry immediately from a valid anchor, otherwise starts one coalesced OCR pass.
    func resolve(_ snapshot: TerminalFocusSnapshot, terminalPID: Int32) -> TerminalFocusSnapshot? {
        guard isEnabled() else {
            invalidate(snapshot.sessionIdentity)
            return nil
        }
        let identity = snapshot.sessionIdentity
        let previous = previousBuffers[identity]
        previousBuffers[identity] = snapshot.commandBuffer
        if snapshot.commandBuffer.isEmpty, previous?.isEmpty == false {
            // Enter advanced the terminal to a fresh row. The old prompt anchor is now stale even
            // though the window itself has not moved.
            anchors[identity] = nil
        }

        let frame = TerminalGeometryResolver.windowFrame(forPid: terminalPID)
        if let anchor = anchors[identity],
           TerminalPromptAnchorResolver.isValid(
               anchor,
               windowFrame: frame,
               cursorOffset: snapshot.cursorCharacterOffset
           ), !(anchor.wasEmptyBuffer && !snapshot.commandBuffer.isEmpty) {
            return applying(anchor: anchor, to: snapshot)
        }

        scheduleCapture(snapshot, terminalPID: terminalPID)
        return nil
    }

    func invalidate(_ identity: TerminalSessionIdentity) {
        captureTasks.removeValue(forKey: identity)?.cancel()
        anchors[identity] = nil
        previousBuffers[identity] = nil
    }

    func invalidateAll() {
        captureTasks.values.forEach { $0.cancel() }
        captureTasks.removeAll()
        anchors.removeAll()
        previousBuffers.removeAll()
    }

    private func scheduleCapture(_ snapshot: TerminalFocusSnapshot, terminalPID: Int32) {
        let identity = snapshot.sessionIdentity
        captureTasks[identity]?.cancel()
        captureTasks[identity] = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: Self.captureDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                let capture = try await captureProvider(snapshot, terminalPID)
                guard !Task.isCancelled else { return }
                let extraction = try await extractor.extractText(from: capture.image)
                guard !Task.isCancelled,
                      let current = latestSnapshotProvider(identity),
                      current.sourceRevision >= snapshot.sourceRevision,
                      current.terminalBundleIdentifier == capture.descriptor.bundleIdentifier,
                      let anchor = TerminalPromptAnchorResolver.makeAnchor(
                          snapshot: current,
                          lines: extraction.positionedLines,
                          captureRegion: capture.region,
                          windowFrame: capture.descriptor.windowFrame
                      ) else { return }
                anchors[identity] = anchor
                onGeometryResolved?(applying(anchor: anchor, to: current))
            } catch is CancellationError {
                return
            } catch {
                logger.debug("Shell prompt geometry unavailable: \(error.localizedDescription)")
            }
            captureTasks[identity] = nil
        }
    }

    private func applying(
        anchor: TerminalPromptAnchor,
        to snapshot: TerminalFocusSnapshot
    ) -> TerminalFocusSnapshot {
        let geometry = TerminalPromptAnchorResolver.geometry(
            cursorOffset: snapshot.cursorCharacterOffset,
            anchor: anchor
        )
        return snapshot.withGeometry(
            windowFrame: AXHelper.cocoaRect(fromAccessibilityRect: anchor.windowFrame),
            cursorRect: AXHelper.cocoaRect(fromAccessibilityRect: geometry.caret),
            promptLineRect: AXHelper.cocoaRect(fromAccessibilityRect: geometry.input),
            observedCellWidth: anchor.cellWidth
        )
    }
}
