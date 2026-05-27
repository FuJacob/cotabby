import Foundation
import Logging

/// File overview:
/// Owns the screenshot-derived prompt-augmentation lifecycle for the currently focused input.
/// This service manages one field-scoped visual-context session at a time and reports state back
/// to `SuggestionCoordinator`, which remains responsible for deciding when to schedule prediction.
@MainActor
final class VisualContextCoordinator {
    /// The coordinator consumes these callbacks to mirror service state into published UI state
    /// without taking back ownership of the visual-context task lifecycle.
    var onStateChange: ((VisualContextStatus, String?) -> Void)?
    var onInjectedContextReady: ((FocusedInputIdentity) -> Void)?

    private let screenshotContextGenerator: ScreenshotContextGenerator
    private let screenRecordingPermissionProvider: @MainActor () -> Bool

    private(set) var status: VisualContextStatus = .idle
    private(set) var latestExcerpt: String?

    private var activeAugmentationSession: FocusedInputAugmentationSession?
    private var visualContextTask: Task<Void, Never>?

    /// Debounce state for the capture pipeline. `pendingStartContext` is the field whose start is
    /// currently waiting out the settle delay; a matching repeat call is ignored so a churning focus
    /// doesn't keep re-arming the timer.
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStartContext: FocusedInputSnapshot?
    private static let sessionStartSettleNanoseconds: UInt64 = 350_000_000

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
    ///
    /// Field identity is checked using both `elementIdentifier` and `focusChangeSequence`.
    /// `elementIdentifier` alone is unreliable because macOS can recycle `CFHash` values
    /// across unrelated AX elements. The monotonic `focusChangeSequence` counter provides a
    /// guaranteed-unique signal that the focus tracker actually observed a new element.
    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot) {
        // Coalesce repeated calls for the same field (active or already pending) so a flapping focus
        // can't restart the pipeline. The decision is pure so the invariants stay unit-testable.
        let incoming = VisualContextFieldIdentity(
            elementIdentifier: snapshotContext.elementIdentifier,
            focusChangeSequence: snapshotContext.focusChangeSequence
        )
        let decision = VisualContextStartCoalescer.decide(
            incoming: incoming,
            active: activeAugmentationSession.map {
                VisualContextFieldIdentity(elementIdentifier: $0.elementIdentifier, focusChangeSequence: $0.focusChangeSequence)
            },
            activeIsBlockedOnScreenRecording: activeIsBlockedOnScreenRecording,
            hasScreenRecordingPermission: screenRecordingPermissionProvider(),
            pending: pendingStartContext.map {
                VisualContextFieldIdentity(elementIdentifier: $0.elementIdentifier, focusChangeSequence: $0.focusChangeSequence)
            }
        )

        switch decision {
        case .ignore:
            return
        case .recoverPermissionThenStart:
            cancel(resetState: true)
        case .start:
            break
        }

        // Debounce the expensive screenshot -> OCR -> summarize pipeline. Chromium/Electron apps
        // flap the focused AX element (lose and re-acquire it), calling this repeatedly with a
        // churning focusChangeSequence. Coalescing (above) plus a short settle window runs the
        // pipeline once focus is stable instead of once per flap — the retrigger storm in #280.
        cancel(resetState: false)
        scheduleSessionStart(for: snapshotContext)
    }

    /// Whether the active session is currently parked on missing Screen Recording permission, so a
    /// permission grant for the same field should restart it rather than be ignored as a duplicate.
    private var activeIsBlockedOnScreenRecording: Bool {
        guard let activeAugmentationSession,
            case .unavailable(let reason) = activeAugmentationSession.status else {
            return false
        }
        return reason.localizedCaseInsensitiveContains("Screen Recording")
    }

    /// Arms a debounced session start. Repeated calls for a churning focus replace the pending
    /// timer, so only the final settled field actually launches the capture pipeline.
    private func scheduleSessionStart(for snapshotContext: FocusedInputSnapshot) {
        pendingStartContext = snapshotContext
        pendingStartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sessionStartSettleNanoseconds)
            guard !Task.isCancelled, let self else {
                return
            }
            self.pendingStartTask = nil
            self.pendingStartContext = nil
            self.launchSession(for: snapshotContext)
        }
    }

    /// Launches the screenshot-derived augmentation session for a settled focused field.
    private func launchSession(for snapshotContext: FocusedInputSnapshot) {
        CotabbyLogger.app.debug("Starting visual context session for element \(snapshotContext.elementIdentifier)")
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

        guard hasPermission else {
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
                    return
                }

                applyExcerpt(
                    excerpt,
                    for: session.sessionID,
                    identity: snapshotContext.identity
                )
            } catch is CancellationError {
                CotabbyLogger.app.debug("Visual context generation cancelled")
                return
            } catch let error as ScreenshotContextGenerationError {
                CotabbyLogger.app.warning("Visual context generation error: \(error.localizedDescription)")
                setStatus(errorStatus(for: error), for: session.sessionID)
            } catch {
                CotabbyLogger.app.error("Visual context generation failed: \(error.localizedDescription)")
                setStatus(.failed(error.localizedDescription), for: session.sessionID)
            }
        }
    }

    /// Clears screenshot-derived context state and cancels any in-flight capture/OCR work.
    /// `resetState` lets callers choose between:
    /// 1. Fully returning the service to `.idle`
    /// 2. Silently tearing down a prior session because a replacement session is about to start
    func cancel(resetState: Bool) {
        pendingStartTask?.cancel()
        pendingStartTask = nil
        pendingStartContext = nil
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
            activeAugmentationSession.focusChangeSequence == context.focusChangeSequence,
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
        identity: FocusedInputIdentity
    ) {
        guard activeAugmentationSession?.sessionID == sessionID,
            activeAugmentationSession?.elementIdentifier == identity.elementIdentifier,
            activeAugmentationSession?.focusChangeSequence == identity.focusChangeSequence
        else {
            return
        }

        activeAugmentationSession?.status = .ready
        activeAugmentationSession?.excerpt = excerpt
        status = .ready
        latestExcerpt = excerpt.text
        CotabbyLogger.app.debug("Visual context ready: \(excerpt.text.count) chars")
        publishState()
        onInjectedContextReady?(identity)
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
}

extension VisualContextCoordinator: VisualContextCoordinating {}
