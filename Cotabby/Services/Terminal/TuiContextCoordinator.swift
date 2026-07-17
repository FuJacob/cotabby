import AppKit
import CoreGraphics
import Foundation
import Logging

/// Owns the debounced, permissioned Claude Code terminal-OCR lifecycle.
///
/// Shell hooks and TUI OCR deliberately remain separate sources: hooks publish exact line-editor
/// state, while a full-screen TUI requires pixels and Screen Recording permission. This coordinator
/// cancels and clears only snapshots it owns, so a late OCR failure cannot tear down a newer shell
/// snapshot from the same terminal.
@MainActor
final class TuiContextCoordinator {
    struct Candidate: Equatable, Sendable {
        let bundleIdentifier: String
        let applicationName: String
        let pid: Int32
        let title: String?
        /// Optional integrated-terminal pane in global Core Graphics coordinates.
        let preferredCaptureRegion: CGRect?
    }

    typealias CandidateProvider = @MainActor () -> Candidate?
    typealias CaptureProvider = @MainActor (Candidate) async throws -> TerminalWindowCapture

    private static let debounceNanoseconds: UInt64 = 180_000_000
    private static let heartbeatNanoseconds: UInt64 = 1_000_000_000

    private let reader: TuiContextReader
    private let candidateProvider: CandidateProvider
    private let captureProvider: CaptureProvider
    private let foregroundProcessProvider: @MainActor (Candidate) -> [String]
    private let isEnabled: @MainActor () -> Bool
    private let isShellActivelyReporting: @MainActor (String) -> Bool
    private let injectSnapshot: @MainActor (FocusedInputSnapshot) -> Void
    private let clearInjection: @MainActor () -> Void
    private let logger = Logger(label: "com.cotabby.terminal-tui")

    private var debounceTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var hasInjectedSnapshot = false
    private var sourceRevision: UInt64 = 0
    private var lastPublishedSignature: String?

    init(
        reader: TuiContextReader,
        candidateProvider: @escaping CandidateProvider,
        captureProvider: @escaping CaptureProvider,
        foregroundProcessProvider: @escaping @MainActor (Candidate) -> [String],
        isEnabled: @escaping @MainActor () -> Bool,
        isShellActivelyReporting: @escaping @MainActor (String) -> Bool,
        injectSnapshot: @escaping @MainActor (FocusedInputSnapshot) -> Void,
        clearInjection: @escaping @MainActor () -> Void
    ) {
        self.reader = reader
        self.candidateProvider = candidateProvider
        self.captureProvider = captureProvider
        self.foregroundProcessProvider = foregroundProcessProvider
        self.isEnabled = isEnabled
        self.isShellActivelyReporting = isShellActivelyReporting
        self.injectSnapshot = injectSnapshot
        self.clearInjection = clearInjection
    }

    func start() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.heartbeatNanoseconds)
                guard !Task.isCancelled else { return }
                self?.evaluateAndSchedule()
            }
        }
        evaluateAndSchedule()
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        cancelPending(clearOwnedSnapshot: true)
    }

    func observeInput() {
        evaluateAndSchedule()
    }

    func settingsOrPermissionChanged() {
        guard isEnabled() else {
            cancelPending(clearOwnedSnapshot: true)
            return
        }
        evaluateAndSchedule()
    }

    private func evaluateAndSchedule() {
        guard isEnabled(), let candidate = candidateProvider() else {
            cancelPending(clearOwnedSnapshot: true)
            return
        }
        guard !isShellActivelyReporting(candidate.bundleIdentifier) else {
            cancelPending(clearOwnedSnapshot: true)
            return
        }

        let classification = TuiSessionDetector.classification(
            bundleIdentifier: candidate.bundleIdentifier,
            terminalAccessibilityTitle: candidate.title,
            foregroundProcessNames: { foregroundProcessProvider(candidate) }
        )
        guard classification != .notClaudeCode else {
            cancelPending(clearOwnedSnapshot: true)
            return
        }

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.capture(candidate: candidate)
        }
    }

    private func capture(candidate: Candidate) async {
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await captureProvider(candidate)
                guard !Task.isCancelled else { return }
                let reading = try await reader.read(image: capture.image)
                guard !Task.isCancelled else { return }

                // OCR is asynchronous. Re-check the frontmost app/window frame before injecting so
                // pixels captured before an app switch can never become current focus afterward.
                guard let current = candidateProvider(),
                      current.bundleIdentifier == candidate.bundleIdentifier,
                      current.pid == candidate.pid,
                      !isShellActivelyReporting(current.bundleIdentifier),
                      windowStillMatches(capture.descriptor.windowFrame, currentPID: current.pid)
                else { return }

                guard reading.looksLikeClaudeCode,
                      reading.promptLineBox != nil else {
                    clearOwnedSnapshot()
                    return
                }

                let geometry = Self.geometry(for: reading, capture: capture)
                let signature = [
                    String(capture.descriptor.windowID),
                    reading.promptText,
                    NSStringFromRect(geometry.caret)
                ].joined(separator: "|")
                guard signature != lastPublishedSignature else { return }
                lastPublishedSignature = signature
                sourceRevision &+= 1
                let snapshot = TuiFocusAdapter.adapt(
                    reading: reading,
                    capture: capture,
                    caretRect: geometry.caret,
                    inputFrameRect: geometry.input,
                    sourceRevision: sourceRevision
                )
                hasInjectedSnapshot = true
                injectSnapshot(snapshot)
            } catch is CancellationError {
                return
            } catch {
                logger.debug("Claude Code OCR unavailable: \(error.localizedDescription)")
                clearOwnedSnapshot()
            }
        }
        await captureTask?.value
    }

    private func cancelPending(clearOwnedSnapshot: Bool) {
        debounceTask?.cancel()
        debounceTask = nil
        captureTask?.cancel()
        captureTask = nil
        if clearOwnedSnapshot { self.clearOwnedSnapshot() }
    }

    private func clearOwnedSnapshot() {
        guard hasInjectedSnapshot else { return }
        hasInjectedSnapshot = false
        lastPublishedSignature = nil
        clearInjection()
    }

    private func windowStillMatches(_ capturedFrame: CGRect, currentPID: Int32) -> Bool {
        guard let currentFrame = TerminalGeometryResolver.windowFrame(forPid: currentPID) else {
            return false
        }
        return abs(currentFrame.minX - capturedFrame.minX) <= 1
            && abs(currentFrame.minY - capturedFrame.minY) <= 1
            && abs(currentFrame.width - capturedFrame.width) <= 1
            && abs(currentFrame.height - capturedFrame.height) <= 1
    }

    private static func geometry(
        for reading: TuiContextReader.PromptReading,
        capture: TerminalWindowCapture
    ) -> (caret: CGRect, input: CGRect) {
        let metrics = TerminalGeometryResolver.defaultCellMetrics
        let box = reading.promptLineBox ?? .zero
        let region = capture.region
        let lineCG = CGRect(
            x: region.minX + box.minX * region.width,
            y: region.minY + (1 - box.maxY) * region.height,
            width: max(box.width * region.width, metrics.cellWidth),
            height: max(box.height * region.height, metrics.cellHeight)
        )
        let caretCG = CGRect(
            x: min(lineCG.maxX + 2, region.maxX - metrics.cellWidth),
            y: lineCG.minY,
            width: metrics.cellWidth,
            height: lineCG.height
        )
        let inputCG = CGRect(
            x: region.minX,
            y: lineCG.minY,
            width: region.width,
            height: lineCG.height
        )
        return (
            AXHelper.cocoaRect(fromAccessibilityRect: caretCG),
            AXHelper.cocoaRect(fromAccessibilityRect: inputCG)
        )
    }
}
