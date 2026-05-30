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

    // Idle backoff. When consecutive captures stop producing changes, the timer runs the expensive
    // AX snapshot walk on a progressively longer stride instead of every tick — the primary fix for
    // #280, where an 80ms poll kept walking Chrome's Accessibility tree ~12.5x/second (and failing)
    // even with no focus change and the user's hands off the keyboard. The transitions live in the
    // pure `FocusPollBackoff` so they can be unit-tested without a live timer.
    private var backoff = FocusPollBackoff()

    // Cached element resolved via cursor hit-testing for Chromium OOPIF editors (e.g. Gmail
    // compose) that the system-wide focused-element query cannot see. Re-validated each tick via
    // AXFocused and dropped the instant it loses focus or the frontmost app changes, so it never
    // masks a real focus change. Paired with `lastChromeProbeSignature` to keep the diagnostic log
    // to one line per focus-resolution change.
    private var chromiumHitTestCache: (element: AXUIElement, pid: pid_t)?
    private var lastChromeProbeSignature: String?

    // Wakes Chromium/Electron web-accessibility trees so their web text becomes readable. Priming
    // is what turns a Chrome renderer from "AX-unaware" (omnibox-only) into a tree the focus
    // queries and hit-test fallback can actually resolve.
    private let chromiumAccessibilityEnabler = ChromiumAccessibilityEnabler()

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
        backoff.reset()
        performCaptureAndPublish()
    }

    /// Timer entry point that applies idle backoff before the expensive Accessibility walk.
    ///
    /// While captures keep producing changes (typing, focus churn) the stride stays at 1 and the
    /// poll runs at full cadence. Once captures stop changing, the stride grows so an idle machine
    /// isn't paying for ~12.5 full Chrome AX tree walks per second — the dominant idle cost in #280.
    private func handleTimerTick() {
        guard backoff.shouldCaptureOnTick() else {
            return
        }
        backoff.recordCapture(didChange: performCaptureAndPublish())
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

    /// Captures the current frontmost application's focused element and reduces it into a snapshot.
    private func captureSnapshot() -> FocusCaptureResult {
        guard permissionProvider() else {
            return inactiveCapture(
                applicationName: "Accessibility permission missing",
                bundleIdentifier: nil,
                capability: .blocked("Accessibility permission is required.")
            )
        }

        // Prime the frontmost app's web-AX tree before reading focus, so a Chromium/Electron
        // renderer is awake by the next tick. No-op for non-Chromium apps and after first success.
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            chromiumAccessibilityEnabler.primeIfNeeded(application: frontmost)
        }

        let focusedElement: AXUIElement
        var preresolvedApplication: NSRunningApplication?
        if let systemFocused = AXHelper.focusedElement() {
            focusedElement = systemFocused
            // System focus works here, so we are not in the OOPIF fallback mode; drop any stale
            // hit-test element so it can never shadow a real focus change.
            chromiumHitTestCache = nil
        } else if let fallback = resolveChromiumFocusFallback() {
            focusedElement = fallback.element
            preresolvedApplication = fallback.application
        } else {
            let frontmost = NSWorkspace.shared.frontmostApplication
            return inactiveCapture(
                applicationName: frontmost?.localizedName ?? "No active application",
                bundleIdentifier: frontmost?.bundleIdentifier,
                capability: .unsupported("No focused Accessibility element.")
            )
        }

        // Identity must come from the app that owns the focused element, not from
        // `frontmostApplication`. Accessory apps with non-activating panels (Raycast, Spotlight,
        // Alfred) leave the previous app frontmost while owning the focused field, so trusting
        // frontmost there would attribute typing to the wrong app and defeat per-app disabling.
        // For a hit-test fallback we trust the frontmost browser (`preresolvedApplication`): the
        // element's own pid can be a renderer subprocess rather than the browser the user sees.
        guard let application = preresolvedApplication
            ?? AXHelper.owningApplication(of: focusedElement)
            ?? NSWorkspace.shared.frontmostApplication else {
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

        let resolveStart = ContinuousClock.now
        let firstPassSnapshot = snapshotResolver.resolveSnapshot(
            focusedElement: focusedElement,
            application: application,
            focusChangeSequence: focusChangeSequence
        )
        logResolveTiming(
            since: resolveStart,
            application: application,
            snapshot: firstPassSnapshot
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

    /// Final link in the focus-resolution chain for Chromium-family apps: when both the system-wide
    /// and app-scoped focused-element queries return nil (the OOPIF case, e.g. Gmail compose),
    /// hit-test at the cursor and climb to the nearest editable container. Runs only for
    /// Chromium/Electron and only after the cheaper queries fail, so the native and normal-Chrome
    /// paths never reach here. The resolved element is cached and re-validated each tick via
    /// AXFocused to avoid re-hit-testing on every poll while the field stays focused.
    private func resolveChromiumFocusFallback() -> (element: AXUIElement, application: NSRunningApplication)? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
            BrowserAppDetector.needsWebAccessibilityPriming(
                bundleIdentifier: frontmost.bundleIdentifier)
        else {
            chromiumHitTestCache = nil
            return nil
        }
        let pid = frontmost.processIdentifier

        // Reuse a still-focused cached hit-test element instead of re-hit-testing every tick.
        if let cache = chromiumHitTestCache, cache.pid == pid, AXHelper.isFocused(cache.element) {
            logChromeFocusProbe(source: "cache", application: frontmost)
            return (cache.element, frontmost)
        }
        chromiumHitTestCache = nil

        // App-scoped focused element: covers some web inputs the system-wide query misses.
        if let appFocused = AXHelper.focusedElement(forApplicationPID: pid) {
            logChromeFocusProbe(source: "app-scoped", application: frontmost)
            return (appFocused, frontmost)
        }

        // Cursor hit-test: the only query that crosses the OOPIF boundary.
        if let hit = AXHelper.element(atCocoaPoint: NSEvent.mouseLocation) {
            let editable = AXHelper.nearestEditable(from: hit)
            chromiumHitTestCache = (editable, pid)
            logChromeFocusProbe(source: "hit-test", application: frontmost)
            return (editable, frontmost)
        }

        return nil
    }

    /// Emits one `[Focus] CHROME-FOCUS-PROBE` line per focus-resolution change (deduplicated by
    /// app + source) so the diagnostic shows which query resolved focus without spamming the log.
    private func logChromeFocusProbe(source: String, application: NSRunningApplication) {
        guard CotabbyDebugOptions.isEnabled else { return }
        let signature = "\(application.processIdentifier):\(source)"
        guard signature != lastChromeProbeSignature else { return }
        lastChromeProbeSignature = signature
        CotabbyLogger.focus.debug(
            "CHROME-FOCUS-PROBE resolved via \(source) for \(application.localizedName ?? "?")")
    }

    /// Logs how long a single `resolveSnapshot` took on the main thread, with the caret source and
    /// cache hit/miss tally. Gated behind `-cotabby-debug`. This is the signal that distinguishes
    /// "keystrokes lag because the synchronous AX resolve is expensive" from other causes — a dump
    /// with consistently high `resolveMs` in a browser confirms the main-thread walk is the stall.
    private func logResolveTiming(
        since start: ContinuousClock.Instant,
        application: NSRunningApplication,
        snapshot: FocusSnapshot
    ) {
        guard CotabbyDebugOptions.isEnabled else {
            return
        }
        let millis = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
        let source = snapshot.context?.caretSource ?? snapshot.capability.shortLabel
        let stats = "no-cache"
        let line = "Resolve timing: app=\(application.localizedName ?? "?") "
            + "resolveMs=\(String(format: "%.1f", millis)) caret=\(source) cache=[\(stats)]"
        CotabbyLogger.focus.debug("\(line)")
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
