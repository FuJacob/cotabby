import Foundation

/// File overview:
/// Owns the screenshot-derived prompt-augmentation lifecycle for the currently focused input.
/// This service manages one field-scoped visual-context session at a time and reports state back
/// to `SuggestionCoordinator`, which remains responsible for deciding when to schedule prediction.
@MainActor
final class VisualContextCoordinator {
    /// The coordinator consumes these callbacks to mirror service state into published UI state
    /// without taking back ownership of the visual-context task lifecycle.
    var onStateChange: ((VisualContextStatus, String?) -> Void)?
    var onInjectedContextReady: ((String) -> Void)?

    private let screenshotContextGenerator: ScreenshotContextGenerator
    private let screenRecordingPermissionProvider: @MainActor () -> Bool

    private(set) var status: VisualContextStatus = .idle
    private(set) var latestSummary: String?

    private var activeAugmentationSession: FocusedInputAugmentationSession?
    private var visualContextTask: Task<Void, Never>?

    private static let permissionMissingReason =
        "Screen Recording permission is required for screenshot-derived prompt context."

    init(
        screenshotContextGenerator: ScreenshotContextGenerator,
        screenRecordingPermissionProvider: @escaping @MainActor () -> Bool
    ) {
        self.screenshotContextGenerator = screenshotContextGenerator
        self.screenRecordingPermissionProvider = screenRecordingPermissionProvider
    }

    /// Starts one screenshot-derived augmentation session per focused field.
    /// This is intentionally scoped to field identity rather than text generation number because
    /// the screenshot context should survive normal typing inside the same input.
    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot) {
        if let activeAugmentationSession,
           activeAugmentationSession.elementIdentifier == snapshotContext.elementIdentifier
        {
            if case .unavailable(let reason) = activeAugmentationSession.status,
               reason.localizedCaseInsensitiveContains("Screen Recording"),
               screenRecordingPermissionProvider()
            {
                cancel(resetState: true)
            } else {
                return
            }
        }

        cancel(resetState: false)

        let initialStatus: VisualContextStatus = screenRecordingPermissionProvider()
            ? .capturing
            : .unavailable(Self.permissionMissingReason)
        let session = FocusedInputAugmentationSession(
            sessionID: UUID(),
            elementIdentifier: snapshotContext.elementIdentifier,
            status: initialStatus,
            injectedContext: nil
        )

        activeAugmentationSession = session
        latestSummary = nil
        status = initialStatus
        publishState()

        guard screenRecordingPermissionProvider() else {
            return
        }

        visualContextTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let injectedContext = try await screenshotContextGenerator.generateContext(
                    for: snapshotContext,
                    onStatusChange: { [weak self] status in
                        await self?.setStatus(status, for: session.sessionID)
                    }
                )
                guard !Task.isCancelled else {
                    return
                }

                applyInjectedContext(
                    injectedContext,
                    for: session.sessionID,
                    elementIdentifier: snapshotContext.elementIdentifier
                )
            } catch is CancellationError {
                return
            } catch let error as ScreenshotContextGenerationError {
                setStatus(errorStatus(for: error), for: session.sessionID)
            } catch {
                setStatus(.failed(error.localizedDescription), for: session.sessionID)
            }
        }
    }

    /// Clears screenshot-derived context state and cancels any in-flight capture/OCR/summary work.
    /// `resetState` lets callers choose between:
    /// 1. Fully returning the service to `.idle`
    /// 2. Silently tearing down a prior session because a replacement session is about to start
    func cancel(resetState: Bool) {
        visualContextTask?.cancel()
        visualContextTask = nil
        activeAugmentationSession = nil
        latestSummary = nil

        if resetState {
            status = .idle
            publishState()
        }
    }

    /// Returns the ready visual-context summary for the provided focused input, if the current
    /// visual-context session still belongs to that same field.
    func summary(for context: FocusedInputContext) -> String? {
        guard let activeAugmentationSession,
              activeAugmentationSession.elementIdentifier == context.elementIdentifier,
              activeAugmentationSession.status == .ready
        else {
            return nil
        }

        return activeAugmentationSession.injectedContext?.summary
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

    /// Commits the generated screenshot summary and reports readiness for the still-focused field.
    private func applyInjectedContext(
        _ injectedContext: InjectedVisualContext,
        for sessionID: UUID,
        elementIdentifier: String
    ) {
        guard activeAugmentationSession?.sessionID == sessionID,
              activeAugmentationSession?.elementIdentifier == elementIdentifier
        else {
            return
        }

        activeAugmentationSession?.status = .ready
        activeAugmentationSession?.injectedContext = injectedContext
        status = .ready
        latestSummary = injectedContext.summary
        publishState()
        onInjectedContextReady?(elementIdentifier)
    }

    private func errorStatus(for error: ScreenshotContextGenerationError) -> VisualContextStatus {
        switch error {
        case let .unavailable(message):
            return .unavailable(message)
        case let .failed(message):
            return .failed(message)
        }
    }

    private func publishState() {
        onStateChange?(status, latestSummary)
    }
}
