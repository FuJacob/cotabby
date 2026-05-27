import AppKit
import Foundation
import Logging

/// File overview:
/// Polls the Accessibility tree on a fixed timer and publishes the latest `FocusSnapshot`.
///
/// Polling is intentionally the only focus-change source. AXObserver delivery is inconsistent in
/// several host apps, and a hybrid push/poll design creates ordering ambiguity. A single polling
/// loop gives Cotabby predictable eventual consistency: every tick re-reads the current frontmost
/// focused element and repairs stale state within one poll interval.
@MainActor
final class FocusTracker {
    var onSnapshotChange: ((FocusSnapshot) -> Void)?
    var onPoll: ((FocusPollingEvent) -> Void)?

    private(set) var snapshot: FocusSnapshot = .inactive {
        didSet {
            onSnapshotChange?(snapshot)
        }
    }

    private var pollInterval: TimeInterval
    private let permissionProvider: @MainActor () -> Bool
    private let ignoredBundleIdentifier: String?
    private let snapshotResolver: FocusSnapshotResolver

    private var timer: Timer?
    private var pollSequence = 0
    private var focusChangeSequence: UInt64 = 0
    private var lastFocusedInputSignature: FocusedInputPollingSignature?

    // Idle backoff state. When consecutive captures stop producing changes, the timer runs the
    // expensive AX snapshot walk on a progressively longer stride instead of every tick. This is
    // the primary fix for #280, where an 80ms poll kept walking Chrome's Accessibility tree
    // ~12.5x/second — and failing — even with no focus change and the user's hands off the keyboard.
    private var idleCaptureCount = 0
    private var ticksSinceCapture = 0
    private static let idleCaptureCountCap = 60

    init(
        pollInterval: TimeInterval = 0.08,
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?,
        snapshotResolver: FocusSnapshotResolver? = nil
    ) {
        self.pollInterval = pollInterval
        self.permissionProvider = permissionProvider
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        // Default resolver construction must happen inside the actor-isolated initializer body.
        // Swift evaluates default parameter expressions before entering the `@MainActor` context.
        self.snapshotResolver = snapshotResolver ?? FocusSnapshotResolver()
    }

    /// Starts periodic AX polling and immediately captures an initial snapshot.
    func start() {
        guard timer == nil else {
            refreshNow()
            return
        }

        CotabbyLogger.focus.info("Focus polling started at \(Int(self.pollInterval * 1000))ms interval")
        refreshNow()

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTimerTick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops polling while leaving the most recent snapshot available to callers.
    func stop() {
        CotabbyLogger.focus.info("Focus polling stopped")
        timer?.invalidate()
        timer = nil
    }

    /// Restarts the polling timer with a new interval. No-op if the interval hasn't changed.
    func updatePollInterval(_ interval: TimeInterval) {
        guard interval != pollInterval else {
            return
        }

        CotabbyLogger.focus.info("Focus poll interval changed to \(Int(interval * 1000))ms")
        pollInterval = interval

        // Only restart if a timer is already running.
        guard timer != nil else {
            return
        }

        stop()
        start()
    }

    /// Performs a synchronous snapshot capture outside the normal polling cadence.
    ///
    /// Other subsystems still call this after input or acceptance events because they know a read is
    /// useful immediately. The implementation is still polling-style: no event is trusted as state;
    /// it only triggers another full AX read. An explicit refresh also resets idle backoff, since it
    /// signals real activity and the poll loop should return to its responsive cadence.
    func refreshNow() {
        idleCaptureCount = 0
        ticksSinceCapture = 0
        performCaptureAndPublish()
    }

    /// Timer entry point that applies idle backoff before the expensive Accessibility walk.
    ///
    /// While captures keep producing changes (typing, focus churn) the stride stays at 1 and the
    /// poll runs at full cadence. Once captures stop changing, the stride grows so an idle machine
    /// isn't paying for ~12.5 full Chrome AX tree walks per second — the dominant idle cost in #280.
    private func handleTimerTick() {
        ticksSinceCapture += 1
        guard ticksSinceCapture >= Self.captureStride(idleCaptureCount: idleCaptureCount) else {
            return
        }
        ticksSinceCapture = 0

        if performCaptureAndPublish() {
            idleCaptureCount = 0
        } else {
            idleCaptureCount = min(idleCaptureCount + 1, Self.idleCaptureCountCap)
        }
    }

    /// Captures the current snapshot, publishes any change, and reports whether anything changed.
    /// Returns `true` when the published snapshot or the focused-input identity changed; idle
    /// backoff uses this to decide whether to stay fast or stretch the poll stride.
    @discardableResult
    private func performCaptureAndPublish() -> Bool {
        pollSequence += 1
        let capture = captureSnapshot()

        let snapshotChanged = capture.snapshot != snapshot
        if snapshotChanged {
            snapshot = capture.snapshot
        }

        onPoll?(
            FocusPollingEvent(
                sequence: pollSequence,
                focusChangeSequence: focusChangeSequence,
                didChangeFocusedInput: capture.didChangeFocusedInput,
                applicationName: capture.snapshot.applicationName,
                capabilitySummary: capture.snapshot.capability.shortLabel,
                occurredAt: Date()
            )
        )

        return snapshotChanged || capture.didChangeFocusedInput
    }

    /// How many base poll ticks to wait between expensive captures, given how many consecutive
    /// captures have produced no change. Pure and `nonisolated` so the backoff schedule is unit-testable.
    ///
    /// The first few idle captures stay at full cadence so a brief pause doesn't make the field feel
    /// laggy; sustained idleness ramps toward ~800ms (at the 80ms base) before the next AX walk.
    nonisolated static func captureStride(idleCaptureCount: Int) -> Int {
        switch idleCaptureCount {
        case ..<5:
            return 1
        case ..<12:
            return 3
        case ..<30:
            return 6
        default:
            return 10
        }
    }

    /// Captures the current frontmost application's focused element and reduces it into a snapshot.
    private func captureSnapshot() -> FocusCaptureResult {
        guard permissionProvider() else {
            return inactiveCapture(
                applicationName: "Accessibility permission missing",
                bundleIdentifier: nil,
                capability: .blocked("Accessibility permission is required.")
            )
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            return inactiveCapture(
                applicationName: "No active application",
                bundleIdentifier: nil,
                capability: .unsupported("No active application.")
            )
        }

        if application.bundleIdentifier == ignoredBundleIdentifier {
            return inactiveCapture(
                applicationName: application.localizedName ?? "Cotabby",
                bundleIdentifier: application.bundleIdentifier,
                capability: .blocked("Cotabby is focused.")
            )
        }

        guard let focusedElement = AXHelper.focusedElement() else {
            return inactiveCapture(
                applicationName: application.localizedName ?? "Unknown",
                bundleIdentifier: application.bundleIdentifier,
                capability: .unsupported("No focused Accessibility element.")
            )
        }

        let firstPassSnapshot = snapshotResolver.resolveSnapshot(
            focusedElement: focusedElement,
            application: application,
            focusChangeSequence: focusChangeSequence
        )

        guard let context = firstPassSnapshot.context else {
            return FocusCaptureResult(
                snapshot: firstPassSnapshot,
                didChangeFocusedInput: clearFocusedInputSignatureIfNeeded()
            )
        }

        let nextSignature = FocusedInputPollingSignature(context: context)
        guard nextSignature != lastFocusedInputSignature else {
            return FocusCaptureResult(snapshot: firstPassSnapshot, didChangeFocusedInput: false)
        }

        lastFocusedInputSignature = nextSignature
        focusChangeSequence += 1

        let finalSnapshot = snapshotResolver.resolveSnapshot(
            focusedElement: focusedElement,
            application: application,
            focusChangeSequence: focusChangeSequence
        )
        return FocusCaptureResult(snapshot: finalSnapshot, didChangeFocusedInput: true)
    }

    private func inactiveCapture(
        applicationName: String,
        bundleIdentifier: String?,
        capability: FocusCapability
    ) -> FocusCaptureResult {
        FocusCaptureResult(
            snapshot: FocusSnapshot(
                applicationName: applicationName,
                bundleIdentifier: bundleIdentifier,
                capability: capability,
                context: nil,
                inspection: nil
            ),
            didChangeFocusedInput: clearFocusedInputSignatureIfNeeded()
        )
    }

    /// Clears the last field signature when polling no longer finds a usable focused input.
    ///
    /// This matters for a later return to the same AX element. Leaving and re-entering a field is a
    /// new focus session for visual context even if the host app reuses the same AX object.
    private func clearFocusedInputSignatureIfNeeded() -> Bool {
        guard lastFocusedInputSignature != nil else {
            return false
        }

        lastFocusedInputSignature = nil
        focusChangeSequence += 1
        return true
    }
}

private struct FocusCaptureResult {
    let snapshot: FocusSnapshot
    let didChangeFocusedInput: Bool
}

/// Stable-enough identity for one focused input as observed by polling.
///
/// Text, selection, and caret position are deliberately excluded. Those can change inside the same
/// field and should not restart the visual-context session. The input frame is preferred over the
/// AX element id because AX identifiers are derived from Core Foundation object identity, which can
/// be recycled by macOS.
private struct FocusedInputPollingSignature: Equatable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let role: String
    let subrole: String?
    let fieldAnchor: FieldAnchor

    init(context: FocusedInputSnapshot) {
        bundleIdentifier = context.bundleIdentifier
        processIdentifier = context.processIdentifier
        role = context.role
        subrole = context.subrole
        fieldAnchor = FieldAnchor(
            inputFrame: context.inputFrameRect,
            fallbackElementIdentifier: context.elementIdentifier
        )
    }
}

private extension FocusedInputPollingSignature {
    struct FieldAnchor: Equatable {
        let roundedInputFrame: RoundedRect?
        let fallbackElementIdentifier: String?

        init(inputFrame: CGRect?, fallbackElementIdentifier: String) {
            roundedInputFrame = inputFrame.map { RoundedRect(rect: $0) }
            self.fallbackElementIdentifier = roundedInputFrame == nil ? fallbackElementIdentifier : nil
        }
    }

    struct RoundedRect: Equatable {
        let minX: Int
        let minY: Int
        let width: Int
        let height: Int

        init(rect: CGRect) {
            minX = Int(rect.minX.rounded())
            minY = Int(rect.minY.rounded())
            width = Int(rect.width.rounded())
            height = Int(rect.height.rounded())
        }
    }
}
