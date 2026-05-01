import Foundation

/// File overview:
/// Owns the screenshot-derived prompt-augmentation lifecycle for the currently focused input.
/// This service manages one field-scoped visual-context session at a time and reports state back
/// to `SuggestionCoordinator`, which remains responsible for deciding when to schedule prediction.
///
/// DEPRECATED:
/// The active suggestion request path no longer uses screenshot/OCR prompt injection in either
/// prompt mode. This coordinator remains in place temporarily for the planned context-system rebuild.
@MainActor
final class VisualContextCoordinator {
    /// The coordinator consumes these callbacks to mirror service state into published UI state
    /// without taking back ownership of the visual-context task lifecycle.
    var onStateChange: ((VisualContextStatus, String?) -> Void)?
    var onInjectedContextReady: ((String) -> Void)?

    private let screenshotContextGenerator: ScreenshotContextGenerator
    private let screenRecordingPermissionProvider: @MainActor () -> Bool
    private weak var diagnosticsLogger: (any DiagnosticsLogging)?

    private(set) var status: VisualContextStatus = .idle
    private(set) var latestExcerpt: String?

    private var activeAugmentationSession: FocusedInputAugmentationSession?
    private var visualContextTask: Task<Void, Never>?

    private static let permissionMissingReason =
        "Screen Recording permission is required for screenshot-derived prompt context."

    init(
        screenshotContextGenerator: ScreenshotContextGenerator,
        screenRecordingPermissionProvider: @escaping @MainActor () -> Bool,
        diagnosticsLogger: (any DiagnosticsLogging)? = nil
    ) {
        self.screenshotContextGenerator = screenshotContextGenerator
        self.screenRecordingPermissionProvider = screenRecordingPermissionProvider
        self.diagnosticsLogger = diagnosticsLogger
    }

    /// Starts one screenshot-derived augmentation session per focused field.
    /// This is intentionally scoped to field identity rather than text generation number because
    /// the screenshot context should survive normal typing inside the same input.
    ///
    /// Field identity is checked using both `elementIdentifier` and `focusChangeSequence`.
    /// `elementIdentifier` alone is unreliable because macOS can recycle `CFHash` values
    /// across unrelated AX elements. The monotonic `focusChangeSequence` counter provides a
    /// guaranteed-unique signal that the focus tracker actually observed a new element.
    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot) {
        if let activeAugmentationSession,
            activeAugmentationSession.elementIdentifier == snapshotContext.elementIdentifier,
            activeAugmentationSession.focusChangeSequence == snapshotContext.focusChangeSequence
        {
            if case .unavailable(let reason) = activeAugmentationSession.status,
                reason.localizedCaseInsensitiveContains("Screen Recording"),
                screenRecordingPermissionProvider()
            {
                cancel(resetState: true)
            } else {
                log("session-dedup element=\(snapshotContext.elementIdentifier) seq=\(snapshotContext.focusChangeSequence) status=\(activeAugmentationSession.status)")
                return
            }
        }

        cancel(resetState: false)

        let hasPermission = screenRecordingPermissionProvider()
        let initialStatus: VisualContextStatus =
            hasPermission
            ? .capturing
            : .unavailable(Self.permissionMissingReason)
        let session = FocusedInputAugmentationSession(
            sessionID: UUID(),
            elementIdentifier: snapshotContext.elementIdentifier,
            focusChangeSequence: snapshotContext.focusChangeSequence,
            status: initialStatus,
            excerpt: nil
        )

        activeAugmentationSession = session
        latestExcerpt = nil
        status = initialStatus
        publishState()

        log("session-start element=\(snapshotContext.elementIdentifier) seq=\(snapshotContext.focusChangeSequence) permission=\(hasPermission)")

        guard hasPermission else {
            log("session-blocked missing-screen-recording-permission")
            return
        }

        visualContextTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let excerpt = try await screenshotContextGenerator.generateContext(
                    for: snapshotContext,
                    onStatusChange: { [weak self] status in
                        await self?.setStatus(status, for: session.sessionID)
                    }
                )
                guard !Task.isCancelled else {
                    log("session-cancelled-after-generate sessionID=\(session.sessionID)")
                    return
                }

                applyExcerpt(
                    excerpt,
                    for: session.sessionID,
                    elementIdentifier: snapshotContext.elementIdentifier
                )
            } catch is CancellationError {
                log("session-cancellation sessionID=\(session.sessionID)")
                return
            } catch let error as ScreenshotContextGenerationError {
                log("session-error sessionID=\(session.sessionID) error=\(error.localizedDescription)")
                setStatus(errorStatus(for: error), for: session.sessionID)
            } catch {
                log("session-error sessionID=\(session.sessionID) error=\(error.localizedDescription)")
                setStatus(.failed(error.localizedDescription), for: session.sessionID)
            }
        }
    }

    /// Clears screenshot-derived context state and cancels any in-flight capture/OCR work.
    /// `resetState` lets callers choose between:
    /// 1. Fully returning the service to `.idle`
    /// 2. Silently tearing down a prior session because a replacement session is about to start
    func cancel(resetState: Bool) {
        visualContextTask?.cancel()
        visualContextTask = nil
        activeAugmentationSession = nil
        latestExcerpt = nil

        if resetState {
            status = .idle
            publishState()
        }
    }

    /// Returns the ready visual-context excerpt for the provided focused input, if the current
    /// visual-context session still belongs to that same field.
    func excerpt(for context: FocusedInputContext) -> String? {
        guard let activeAugmentationSession,
            activeAugmentationSession.elementIdentifier == context.elementIdentifier,
            activeAugmentationSession.status == .ready
        else {
            return nil
        }

        return activeAugmentationSession.excerpt?.text
    }

    /// Updates only the current augmentation session so stale async screenshot work cannot mutate
    /// the next field after focus changes.
    private func setStatus(_ status: VisualContextStatus, for sessionID: UUID) {
        guard activeAugmentationSession?.sessionID == sessionID else {
            return
        }

        activeAugmentationSession?.status = status
        self.status = status
        publishState()
    }

    /// Commits the generated screenshot excerpt and reports readiness for the still-focused field.
    private func applyExcerpt(
        _ excerpt: VisualContextExcerpt,
        for sessionID: UUID,
        elementIdentifier: String
    ) {
        guard activeAugmentationSession?.sessionID == sessionID,
            activeAugmentationSession?.elementIdentifier == elementIdentifier
        else {
            return
        }

        activeAugmentationSession?.status = .ready
        activeAugmentationSession?.excerpt = excerpt
        status = .ready
        latestExcerpt = excerpt.text
        publishState()
        onInjectedContextReady?(elementIdentifier)
    }

    private func errorStatus(for error: ScreenshotContextGenerationError) -> VisualContextStatus {
        switch error {
        case .unavailable(let message):
            return .unavailable(message)
        case .failed(let message):
            return .failed(message)
        }
    }

    private func publishState() {
        onStateChange?(status, latestExcerpt)
    }

    private func log(_ message: String) {
        diagnosticsLogger?.trace(
            category: .visual,
            component: "VisualContextCoordinator",
            message: message
        )
    }
}

extension VisualContextCoordinator: VisualContextCoordinating {}
