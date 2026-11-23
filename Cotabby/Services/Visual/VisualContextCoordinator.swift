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

    /// The session lifecycle. Status and excerpt are derived from it, never stored beside it.
    private var phase = VisualContextSessionPhase.idle
    private var tasks = Tasks()

    var status: VisualContextStatus { phase.status }
    var latestExcerpt: String? { phase.excerpt?.text }

    /// The async work a session can have in flight. All of it belongs to the current phase, so it
    /// is always cancelled together when the session ends.
    private struct Tasks {
        /// Waits out the settle delay before a field's capture pipeline launches.
        var settle: Task<Void, Never>?
        var capture: Task<Void, Never>?
        var refresh: Task<Void, Never>?
        var expiry: Task<Void, Never>?

        mutating func cancelAll() {
            for task in [settle, capture, refresh, expiry] {
                task?.cancel()
            }
            self = Tasks()
        }
    }

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
            cancel()
            return
        }
        if self.configuration != configuration {
            cancel()
            self.configuration = configuration
        }
        // Surface facts can change even when an app reuses its composer and AX handle. Drop the
        // old excerpt synchronously; the settle delay below must never expose another chat's text.
        if let previous = phase.surface, !snapshotContext.sessionIdentity.continues(previous) {
            cancel()
        }
        // Coalesce repeated calls for the same field (active or already pending) so a flapping focus
        // can't restart the pipeline. The decision is pure so the invariants stay unit-testable.
        let decision = VisualContextStartCoalescer.decide(
            incoming: snapshotContext.identity,
            active: phase.session?.field,
            activeIsBlockedOnScreenRecording: phase.isBlockedOnPermission,
            hasScreenRecordingPermission: screenRecordingPermissionProvider(),
            pending: phase.settlingField
        )

        guard decision == .start else {
            return
        }

        // Debounce the expensive screenshot -> OCR -> cleanup pipeline. Chromium/Electron apps
        // flap the focused AX element (lose and re-acquire it), calling this repeatedly with a
        // churning focusChangeSequence. Coalescing (above) plus a short settle window runs the
        // pipeline once focus is stable instead of once per flap — the retrigger storm in #280.
        cancel()
        scheduleSessionStart(for: snapshotContext)
    }

    /// Arms a debounced session start. Repeated calls for a churning focus replace the pending
    /// timer, so only the final settled field actually launches the capture pipeline.
    private func scheduleSessionStart(for snapshotContext: FocusedInputSnapshot) {
        phase = .settling(field: snapshotContext.identity, surface: snapshotContext.sessionIdentity)
        tasks.settle = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sessionStartSettleNanoseconds)
            guard !Task.isCancelled, let self else {
                return
            }
            self.tasks.settle = nil
            self.launchSession(for: snapshotContext)
        }
    }

    /// Launches the screenshot-derived augmentation session for a settled focused field.
    private func launchSession(for snapshotContext: FocusedInputSnapshot) {
        CotabbyLogger.app.debug("Starting visual context session for element \(snapshotContext.elementIdentifier)")
        let hasPermission = screenRecordingPermissionProvider()
        let session = VisualContextSession(
            id: UUID(),
            field: snapshotContext.identity,
            surface: snapshotContext.sessionIdentity
        )
        phase.launch(session, hasPermission: hasPermission, permissionMissingReason: Self.permissionMissingReason)
        publishState()

        guard hasPermission else {
            return
        }

        var captureContext = snapshotContext
        if let provider = refreshContextProvider {
            let currentContext = provider()
            guard !Task.isCancelled, phase.session?.id == session.id else { return }
            guard screenRecordingPermissionProvider(), let currentContext,
                  currentContext.identity == snapshotContext.identity,
                  currentContext.sessionIdentity.continues(snapshotContext.sessionIdentity), !currentContext.isSecure else {
                cancel()
                return
            }
            captureContext = currentContext
        }
        capture(context: captureContext, session: session)
    }

    /// Keep the last ready excerpt usable during refresh. Capture and OCR never gate generation;
    /// only a completed, still-current result can replace the context used by subsequent requests.
    private func capture(context snapshotContext: FocusedInputSnapshot, session: VisualContextSession) {
        // Age starts before capture, not after OCR: a slow result cannot renew old pixels.
        let capturedAt = now()
        tasks.capture = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let excerpt = try await screenshotContextGenerator.generateContext(
                    for: snapshotContext,
                    configuration: configuration,
                    onStatusChange: { [weak self] status in
                        self?.reportCaptureProgress(status, for: session.id)
                    }
                )
                guard !Task.isCancelled else {
                    return
                }
                // The field's text on both sides of the screenshot: an accept can land after the
                // read above and before the pixels are taken, and its words must still read as the
                // user's own edit rather than new screen text.
                var fieldTexts = [snapshotContext.precedingText + snapshotContext.trailingText]
                if let provider = refreshContextProvider {
                    let liveContext = provider()
                    guard phase.session?.id == session.id else { return }
                    guard screenRecordingPermissionProvider(), let liveContext,
                          liveContext.identity == snapshotContext.identity,
                          liveContext.sessionIdentity.continues(snapshotContext.sessionIdentity),
                          !liveContext.isSecure else {
                        cancel()
                        return
                    }
                    fieldTexts.append(liveContext.precedingText + liveContext.trailingText)
                }

                applyExcerpt(
                    excerpt,
                    for: session.id,
                    identity: snapshotContext.identity,
                    capturedAt: capturedAt,
                    fieldTexts: fieldTexts
                )
                phase.learnSurfaceFacts(from: snapshotContext.sessionIdentity, captured: excerpt, sessionID: session.id)
            } catch is CancellationError {
                CotabbyLogger.app.debug("Visual context generation cancelled")
                return
            } catch let error as ScreenshotContextGenerationError {
                CotabbyLogger.app.warning("Visual context generation error: \(error.localizedDescription)")
                reportCaptureError(error, for: session.id)
            } catch {
                CotabbyLogger.app.error("Visual context generation failed: \(error.localizedDescription)")
                didChangePhase(phase.markFailed(reason: error.localizedDescription, sessionID: session.id))
            }
            guard !Task.isCancelled, phase.session?.id == session.id else { return }
            tasks.capture = nil
            scheduleRefresh(sessionID: session.id)
        }
    }

    /// One timer per field, rearmed only after capture completes: slow OCR cannot accumulate jobs.
    /// Refresh uses the same engine-specific crop and limits as the initial capture. In particular,
    /// enabling endpoint refresh does not widen what can reach a network request.
    private func scheduleRefresh(sessionID: UUID) {
        guard refreshContextProvider != nil else { return }
        let delay = refreshIntervalNanoseconds
        tasks.refresh = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled,
                  self.phase.session?.id == sessionID else { return }
            let liveContext = self.refreshContextProvider?()
            // Refreshing AX can synchronously publish a different field and start its session.
            // Never cancel that replacement on behalf of this old timer. The session is re-read
            // here because a capture may have filled in surface facts since the timer was armed.
            guard let session = self.phase.session, session.id == sessionID else { return }
            guard self.screenRecordingPermissionProvider(),
                  let context = liveContext,
                  context.identity == session.field,
                  context.sessionIdentity.continues(session.surface),
                  !context.isSecure else {
                self.cancel()
                return
            }
            self.capture(context: context, session: session)
        }
    }

    /// Clears screenshot-derived context state, cancels any in-flight capture/OCR work, and
    /// publishes `.idle`.
    func cancel() {
        tasks.cancelAll()
        phase = .idle
        publishState()
    }

    /// Returns the ready visual-context excerpt for the provided focused input, if the current
    /// visual-context session still belongs to that same field.
    func excerpt(for context: FocusedInputContext) -> String? {
        expireExcerptIfNeeded()
        // Exact identity here, unlike the session-keeping checks above. Those tolerate a surface
        // fact the poll failed to read so a busy host does not cancel the capture; this call hands
        // screen text to a prompt, and a chat switch that reuses the composer, frame and URL while
        // its new title is momentarily unreadable would otherwise condition the new chat's request
        // on the previous chat's excerpt. Withholding the excerpt for that one poll costs a request
        // its screen context; the session and its capture survive for the next readable poll.
        guard case .ready(let session, let excerpt, _) = phase,
            session.surface == context.sessionIdentity,
            session.field.elementIdentifier == context.elementIdentifier,
            session.field.focusChangeSequence == context.focusChangeSequence
        else {
            return nil
        }

        return excerpt.text
    }

    /// Forwards the generator's progress into the phase. Only the two in-flight stages are
    /// meaningful here; outcomes arrive as a returned excerpt or a thrown error instead.
    private func reportCaptureProgress(_ status: VisualContextStatus, for sessionID: UUID) {
        let stage: VisualContextSessionPhase.CaptureStage
        switch status {
        case .capturing:
            stage = .capturingScreen
        case .extractingText:
            stage = .extractingText
        case .idle, .ready, .unavailable, .failed:
            return
        }
        didChangePhase(phase.captureProgressed(to: stage, sessionID: sessionID))
    }

    private func reportCaptureError(_ error: ScreenshotContextGenerationError, for sessionID: UUID) {
        switch error {
        case .permissionMissing(let message):
            didChangePhase(phase.markBlockedOnPermission(reason: message, sessionID: sessionID))
        case .unavailable(let message):
            didChangePhase(phase.markUnavailable(reason: message, sessionID: sessionID))
        case .failed(let message):
            didChangePhase(phase.markFailed(reason: message, sessionID: sessionID))
        }
    }

    /// Follows up a phase transition that came from async screenshot work. `applied` is false when
    /// the work belonged to a session that is no longer current, in which case nothing is published.
    private func didChangePhase(_ applied: Bool) {
        guard applied else {
            return
        }
        if phase.excerpt == nil {
            tasks.expiry?.cancel()
            tasks.expiry = nil
        }
        publishState()
    }

    /// Commits the generated screenshot excerpt and reports readiness for the still-focused field.
    private func applyExcerpt(
        _ excerpt: VisualContextExcerpt,
        for sessionID: UUID,
        identity: FocusedInputIdentity,
        capturedAt: TimeInterval,
        fieldTexts: [String]
    ) {
        guard let session = phase.session, session.id == sessionID, session.field == identity else {
            return
        }

        guard now() - capturedAt < Double(excerptLifetimeNanoseconds) / 1_000_000_000 else {
            didChangePhase(
                phase.markUnavailable(reason: "Screen context expired before recognition completed.", sessionID: sessionID)
            )
            return
        }

        // OCR reads an unchanged screen a little differently on every refresh. When the new reading
        // is the same screen as far as `VisualContextExcerptStability` can tell, keep the excerpt in
        // use byte-identical: no navigation signal, and the llama prompt head (and its KV prefix)
        // stays put. The kept text takes the new capture's age, since it still describes the screen.
        let current = phase.excerpt
        let adopted: VisualContextExcerpt
        if let current, !VisualContextExcerptStability.isMaterialChange(from: current.text, to: excerpt.text) {
            adopted = current
            if current.text != excerpt.text {
                CotabbyLogger.app.debug("Visual context refresh kept the current excerpt; only OCR jitter changed")
            }
        } else {
            adopted = excerpt
        }
        let changed = current?.text != adopted.text
        // A material change is reported as possible navigation so the coordinator retires the
        // visible tail, but only when it shows text the old screen and the field's own text do not
        // account for: accepted words landing on screen are not navigation, and reporting them
        // replaced the suggestion mid-accept whenever the user paused between Tabs. An edit cannot
        // hide a navigation that brings lines of its own. The excerpt is stored either way, so the
        // next request uses it. A first excerpt is always reported: it is new context, not a
        // comparison.
        let isNavigation = changed && (current.map {
            OCRTextHygiene.showsUnexplainedText(adopted.text, previous: $0.text, fieldTexts: fieldTexts)
        } ?? true)
        guard phase.adopt(adopted, capturedAt: capturedAt, sessionID: sessionID) else {
            return
        }
        scheduleExpiry(sessionID: sessionID, capturedAt: capturedAt)
        CotabbyLogger.app.debug("Visual context ready: \(adopted.text.count) chars")
        publishState()
        if isNavigation {
            onInjectedContextReady?(identity)
        } else if changed {
            CotabbyLogger.app.debug("Visual context changed only by the field's own text or OCR noise; not navigation")
        }
    }

    /// Timer-driven expiry updates the UI and request-driven expiry covers a delayed timer. Both
    /// use monotonic uptime so changing the system clock cannot extend an excerpt's lifetime.
    private func expireExcerptIfNeeded() {
        guard let capturedAt = phase.excerptCapturedAt, let session = phase.session,
              now() - capturedAt >= Double(excerptLifetimeNanoseconds) / 1_000_000_000 else { return }
        didChangePhase(
            phase.markUnavailable(reason: "Screen context expired; waiting for a fresh capture.", sessionID: session.id)
        )
    }

    private func scheduleExpiry(sessionID: UUID, capturedAt: TimeInterval) {
        tasks.expiry?.cancel()
        let remaining = max(0, Double(excerptLifetimeNanoseconds) / 1_000_000_000 - (now() - capturedAt))
        tasks.expiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
            guard let self, self.phase.session?.id == sessionID,
                  self.phase.excerptCapturedAt == capturedAt else { return }
            self.expireExcerptIfNeeded()
        }
    }

    private func publishState() {
        onStateChange?(status, latestExcerpt)
    }
}

extension VisualContextCoordinator: VisualContextCoordinating {}
