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
    var refreshContextProvider: (() -> FocusedInputSnapshot?)?

    private let screenshotContextGenerator: any ScreenshotContextGenerating
    private let screenRecordingPermissionProvider: @MainActor () -> Bool
    private let refreshIntervalNanoseconds: UInt64
    private let excerptLifetimeNanoseconds: UInt64
    private let now: () -> TimeInterval
    private var configuration = VisualContextConfiguration.default
    private var refreshTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var excerptCapturedAt: TimeInterval?
    private var activeSessionIdentity: FocusedInputSessionIdentity?

    private(set) var status: VisualContextStatus = .idle
    private(set) var latestExcerpt: String?

    private var activeAugmentationSession: FocusedInputAugmentationSession?
    private var visualContextTask: Task<Void, Never>?

    /// Debounce state for the capture pipeline. `pendingStartContext` is the field whose start is
    /// currently waiting out the settle delay; a matching repeat call is ignored so a churning focus
    /// doesn't keep re-arming the timer.
    private var pendingStartTask: Task<Void, Never>?
    private var pendingStartContext: FocusedInputSnapshot?
    private static let sessionStartSettleNanoseconds: UInt64 = 250_000_000

    private static let permissionMissingReason =
        "Screen Recording permission is required for screenshot-derived prompt context."

    init(
        screenshotContextGenerator: any ScreenshotContextGenerating,
        screenRecordingPermissionProvider: @escaping @MainActor () -> Bool,
        refreshIntervalNanoseconds: UInt64 = 3_000_000_000,
        excerptLifetimeNanoseconds: UInt64 = 6_000_000_000,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.screenshotContextGenerator = screenshotContextGenerator
        self.screenRecordingPermissionProvider = screenRecordingPermissionProvider
        self.refreshIntervalNanoseconds = refreshIntervalNanoseconds
        self.excerptLifetimeNanoseconds = excerptLifetimeNanoseconds
        self.now = now
    }

    /// Starts one screenshot-derived augmentation session per focused field.
    /// This is intentionally scoped to field identity rather than text generation number because
    /// the screenshot context should survive normal typing inside the same input.
    ///
    /// Field identity is checked using both `elementIdentifier` and `focusChangeSequence`.
    /// `elementIdentifier` alone is unreliable because macOS can recycle `CFHash` values
    /// across unrelated AX elements. The monotonic `focusChangeSequence` counter provides a
    /// guaranteed-unique signal that the focus tracker actually observed a new element.
    func startSessionIfNeeded(
        for snapshotContext: FocusedInputSnapshot,
        configuration: VisualContextConfiguration = .default
    ) {
        guard !snapshotContext.isSecure else {
            cancel(resetState: true)
            return
        }
        if self.configuration != configuration {
            cancel(resetState: true)
            self.configuration = configuration
        }
        // Surface facts can change even when an app reuses its composer and AX handle. Drop the
        // old excerpt synchronously; the settle delay below must never expose another chat's text.
        if let previous = activeSessionIdentity ?? pendingStartContext?.sessionIdentity,
           previous != snapshotContext.sessionIdentity {
            cancel(resetState: true)
        }
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

        // Debounce the expensive screenshot -> OCR -> cleanup pipeline. Chromium/Electron apps
        // flap the focused AX element (lose and re-acquire it), calling this repeatedly with a
        // churning focusChangeSequence. Coalescing (above) plus a short settle window runs the
        // pipeline once focus is stable instead of once per flap — the retrigger storm in #280.
        cancel(resetState: true)
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
        activeSessionIdentity = snapshotContext.sessionIdentity
        latestExcerpt = nil
        status = initialStatus
        publishState()

        guard hasPermission else {
            return
        }

        var captureContext = snapshotContext
        if let provider = refreshContextProvider {
            let currentContext = provider()
            guard !Task.isCancelled, activeAugmentationSession?.sessionID == session.sessionID else { return }
            guard screenRecordingPermissionProvider(), let currentContext,
                  currentContext.identity == snapshotContext.identity,
                  currentContext.sessionIdentity == snapshotContext.sessionIdentity, !currentContext.isSecure else {
                cancel(resetState: true)
                return
            }
            captureContext = currentContext
        }
        capture(context: captureContext, session: session)
    }

    /// Keep the last ready excerpt usable during refresh. Capture and OCR never gate generation;
    /// only a completed, still-current result can replace the context used by subsequent requests.
    private func capture(context snapshotContext: FocusedInputSnapshot, session: FocusedInputAugmentationSession) {
        // Age starts before capture, not after OCR: a slow result cannot renew old pixels.
        let capturedAt = now()
        visualContextTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let excerpt = try await screenshotContextGenerator.generateContext(
                    for: snapshotContext,
                    configuration: configuration,
                    onStatusChange: { [weak self] status in
                        self?.setStatus(status, for: session.sessionID)
                    }
                )
                guard !Task.isCancelled else {
                    return
                }
                if let provider = refreshContextProvider {
                    let liveContext = provider()
                    guard activeAugmentationSession?.sessionID == session.sessionID else { return }
                    guard screenRecordingPermissionProvider(), liveContext?.identity == snapshotContext.identity,
                          liveContext?.sessionIdentity == snapshotContext.sessionIdentity,
                          liveContext?.isSecure == false else {
                        cancel(resetState: true)
                        return
                    }
                }

                applyExcerpt(
                    excerpt,
                    for: session.sessionID,
                    identity: snapshotContext.identity,
                    capturedAt: capturedAt
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
            guard !Task.isCancelled, activeAugmentationSession?.sessionID == session.sessionID else { return }
            visualContextTask = nil
            scheduleRefresh(sessionID: session.sessionID)
        }
    }

    /// One timer per field, rearmed only after capture completes: slow OCR cannot accumulate jobs.
    /// Refresh uses the same engine-specific crop and limits as the initial capture. In particular,
    /// enabling endpoint refresh does not widen what can reach a network request.
    private func scheduleRefresh(sessionID: UUID) {
        guard refreshContextProvider != nil else { return }
        let delay = refreshIntervalNanoseconds
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled,
                  let session = self.activeAugmentationSession, session.sessionID == sessionID else { return }
            let liveContext = self.refreshContextProvider?()
            // Refreshing AX can synchronously publish a different field and start its session.
            // Never cancel that replacement on behalf of this old timer.
            guard self.activeAugmentationSession?.sessionID == sessionID else { return }
            guard self.screenRecordingPermissionProvider(),
                  let context = liveContext,
                  context.elementIdentifier == session.elementIdentifier,
                  context.focusChangeSequence == session.focusChangeSequence,
                  context.sessionIdentity == self.activeSessionIdentity,
                  !context.isSecure else {
                self.cancel(resetState: true)
                return
            }
            self.capture(context: context, session: session)
        }
    }

    /// Clears screenshot-derived context state and cancels any in-flight capture/OCR work.
    /// `resetState` lets callers choose between:
    /// 1. Fully returning the service to `.idle`
    /// 2. Silently tearing down a prior session because a replacement session is about to start
    func cancel(resetState: Bool) {
        expiryTask?.cancel()
        expiryTask = nil
        excerptCapturedAt = nil
        activeSessionIdentity = nil
        refreshTask?.cancel()
        refreshTask = nil
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
        expireExcerptIfNeeded()
        guard let activeAugmentationSession,
            activeSessionIdentity == context.sessionIdentity,
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

        if activeAugmentationSession?.excerpt != nil, status == .capturing || status == .extractingText {
            return
        }
        // Failed/blank captures must not leave an old conversation masquerading as current context.
        if case .unavailable = status {
            activeAugmentationSession?.excerpt = nil
            latestExcerpt = nil
        } else if case .failed = status {
            activeAugmentationSession?.excerpt = nil
            latestExcerpt = nil
        }
        if latestExcerpt == nil {
            excerptCapturedAt = nil
            expiryTask?.cancel()
            expiryTask = nil
        }
        activeAugmentationSession?.status = status
        self.status = status
        publishState()
    }

    /// Commits the generated screenshot excerpt and reports readiness for the still-focused field.
    private func applyExcerpt(
        _ excerpt: VisualContextExcerpt,
        for sessionID: UUID,
        identity: FocusedInputIdentity,
        capturedAt: TimeInterval
    ) {
        guard activeAugmentationSession?.sessionID == sessionID,
            activeAugmentationSession?.elementIdentifier == identity.elementIdentifier,
            activeAugmentationSession?.focusChangeSequence == identity.focusChangeSequence
        else {
            return
        }

        guard now() - capturedAt < Double(excerptLifetimeNanoseconds) / 1_000_000_000 else {
            setStatus(.unavailable("Screen context expired before recognition completed."), for: sessionID)
            return
        }

        let changed = activeAugmentationSession?.excerpt?.text != excerpt.text
        activeAugmentationSession?.status = .ready
        activeAugmentationSession?.excerpt = excerpt
        status = .ready
        latestExcerpt = excerpt.text
        excerptCapturedAt = capturedAt
        scheduleExpiry(sessionID: sessionID, capturedAt: capturedAt)
        CotabbyLogger.app.debug("Visual context ready: \(excerpt.text.count) chars")
        publishState()
        if changed { onInjectedContextReady?(identity) }
    }

    /// Timer-driven expiry updates the UI and request-driven expiry covers a delayed timer. Both
    /// use monotonic uptime so changing the system clock cannot extend an excerpt's lifetime.
    private func expireExcerptIfNeeded() {
        guard let capturedAt = excerptCapturedAt, let session = activeAugmentationSession,
              now() - capturedAt >= Double(excerptLifetimeNanoseconds) / 1_000_000_000 else { return }
        setStatus(.unavailable("Screen context expired; waiting for a fresh capture."), for: session.sessionID)
    }

    private func scheduleExpiry(sessionID: UUID, capturedAt: TimeInterval) {
        expiryTask?.cancel()
        let remaining = max(0, Double(excerptLifetimeNanoseconds) / 1_000_000_000 - (now() - capturedAt))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
            guard let self, self.activeAugmentationSession?.sessionID == sessionID,
                  self.excerptCapturedAt == capturedAt else { return }
            self.expireExcerptIfNeeded()
        }
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
