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
    /// AX identifier of the one element inside Cotabby's own UI that is allowed to be captured: the
    /// Context pane's live-preview field. `nil` (the default) keeps the strict "never complete in our
    /// own process" rule with no exception. Keyed on AX identity rather than bundle so every other
    /// element in Cotabby's windows stays blocked.
    private let selfCaptureAllowedElementIdentifier: String?
    /// Returns true when the focused app's bundle should NOT have its AX tree deep-walked. The
    /// gate runs after the cheap system-wide focused-element query but before the expensive
    /// candidate-elements walk in `FocusSnapshotResolver`. macOS popovers (Calendar's event-detail
    /// popover, in particular) self-dismiss when AX attribute enumeration runs against them, so
    /// disabling Cotabby globally or for a specific app must actually stop the walk, not just
    /// stop generating suggestions on top of it (#476).
    private let isCaptureSuppressedForBundle: @MainActor (String?) -> Bool
    private let snapshotResolver: FocusSnapshotResolver

    private var timer: Timer?
    /// The interval the running `timer` was created with, so idle-backoff transitions can re-arm it
    /// only when the effective interval actually changes (no per-keystroke timer churn while active).
    private var scheduledInterval: TimeInterval?
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

    // Last bundle identifier we logged as suppressed. Used to emit one log line per
    // suppression transition instead of one per 50-80ms poll tick.
    private var lastSuppressedBundleIdentifier: String?

    // Wakes Chromium/Electron web-accessibility trees so their web text becomes readable. Priming
    // is what turns a Chrome renderer from "AX-unaware" (omnibox-only) into a tree the focus
    // queries and hit-test fallback can actually resolve.
    private let chromiumAccessibilityEnabler = ChromiumAccessibilityEnabler()

    init(
        pollInterval: TimeInterval = 0.08,
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?,
        selfCaptureAllowedElementIdentifier: String? = nil,
        isCaptureSuppressedForBundle: @escaping @MainActor (String?) -> Bool = { _ in false },
        snapshotResolver: FocusSnapshotResolver? = nil
    ) {
        self.pollInterval = pollInterval
        self.permissionProvider = permissionProvider
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        self.selfCaptureAllowedElementIdentifier = selfCaptureAllowedElementIdentifier
        self.isCaptureSuppressedForBundle = isCaptureSuppressedForBundle
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
        // Capture once immediately (this also resets idle backoff), then arm the timer at the
        // resulting effective interval.
        refreshNow()
        scheduleTimer()
    }

    /// Stops polling while leaving the most recent snapshot available to callers.
    func stop() {
        CotabbyLogger.focus.info("Focus polling stopped")
        timer?.invalidate()
        timer = nil
        scheduledInterval = nil
    }

    /// The interval the poll timer should currently run at: the base interval stretched by idle
    /// backoff. While the user is active the stride is 1, so this is just `pollInterval`.
    private func effectiveInterval() -> TimeInterval {
        pollInterval * Double(backoff.captureStride)
    }

    /// Creates (or replaces) the poll timer at the current effective interval. Each fire performs
    /// exactly one capture, so an idle machine wakes the main thread every `base * stride` instead of
    /// every base tick. The capture cadence is identical to the previous tick-skipping design; only
    /// the no-op wakeups are removed.
    private func scheduleTimer() {
        timer?.invalidate()
        let interval = effectiveInterval()
        scheduledInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTimerTick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Re-arms the timer only when idle backoff has moved it to a new effective interval. During
    /// active use the stride stays at 1, so this is a no-op and avoids per-keystroke timer churn.
    private func rescheduleTimerIfIntervalChanged() {
        guard timer != nil, effectiveInterval() != scheduledInterval else {
            return
        }
        scheduleTimer()
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
        rescheduleTimerIfIntervalChanged()
    }

    /// Drops resolver caches whose contents Cotabby just made stale by mutating the focused field
    /// itself (the static-run walk after a synthetic insert). The next capture pays fresh walks.
    func invalidateTransientCaretCaches() {
        snapshotResolver.invalidateStaticRunWalkCache()
    }

    /// Timer entry point: capture once, fold the result into idle backoff, then re-arm the timer at
    /// the backoff-derived interval.
    ///
    /// While captures keep producing changes (typing, focus churn) the stride stays at 1 and the
    /// timer stays at the base interval. Once captures stop changing, the stride grows and the timer
    /// is re-armed to a longer interval, so an idle machine stops waking ~12.5x/second only to skip
    /// the walk it would not run anyway. That wasteful wake was the dominant idle cost in #280.
    private func handleTimerTick() {
        backoff.recordCapture(didChange: performCaptureAndPublish())
        rescheduleTimerIfIntervalChanged()
    }

    /// Uptime stamp of the most recent completed capture (timer tick or explicit refresh).
    /// Backs `millisecondsSinceLastCapture` so pipeline consumers can skip a synchronous AX walk
    /// when another caller just performed one. Uses uptime (monotonic) so wall-clock adjustments
    /// cannot fake freshness.
    private var lastCaptureUptimeNanoseconds: UInt64?

    /// Age of the last capture in milliseconds, or `nil` before the first capture.
    var millisecondsSinceLastCapture: Int? {
        guard let lastCaptureUptimeNanoseconds else {
            return nil
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds &- lastCaptureUptimeNanoseconds
        return Int(elapsed / 1_000_000)
    }

    /// Captures the current snapshot, publishes any change, and reports whether anything changed.
    /// Returns `true` when the published snapshot or the focused-input identity changed; idle
    /// backoff uses this to decide whether to stay fast or stretch the poll stride.
    @discardableResult
    private func performCaptureAndPublish() -> Bool {
        pollSequence += 1
        let capture = captureSnapshot()
        lastCaptureUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds

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

        // Cotabby never completes inside its own UI, with one sanctioned exception: the Context pane's
        // live-preview field, tagged with a known AX identifier so the user can exercise the real
        // pipeline against their settings. Every other element in Cotabby's own windows (search field,
        // Extended Context editor, menus) stays blocked, so this cannot leak completions into Settings.
        // The identifier AX read is an autoclosure, so it runs only when Cotabby itself is focused.
        if !SelfCaptureGate.allowsCapture(
            focusedBundleIdentifier: application.bundleIdentifier,
            ignoredBundleIdentifier: ignoredBundleIdentifier,
            focusedElementIdentifier: AXHelper.accessibilityIdentifier(of: focusedElement),
            sanctionedElementIdentifier: selfCaptureAllowedElementIdentifier
        ) {
            return inactiveCapture(
                applicationName: application.localizedName ?? "Cotabby",
                bundleIdentifier: application.bundleIdentifier,
                capability: .blocked("Cotabby is focused.")
            )
        }

        // Bail before any AX deep-walk when Cotabby is disabled for the focused app. Stops
        // `FocusSnapshotResolver.resolveSnapshot` from enumerating attributes on transient popover
        // windows (Calendar's event-detail popover dismisses itself when its AX tree is read out
        // from underneath it — #476). The cheap `AXHelper.focusedElement()` query above is fine to
        // run; only the candidate-elements walk hits the popover.
        if isCaptureSuppressedForBundle(application.bundleIdentifier) {
            noteCaptureSuppressed(for: application)
            return inactiveCapture(
                applicationName: application.localizedName ?? "?",
                bundleIdentifier: application.bundleIdentifier,
                capability: .blocked("Cotabby is disabled for this app.")
            )
        }
        noteCaptureResumedIfNeeded()

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

    /// Emits one log line per suppression transition. The gate is consulted on every poll tick, so
    /// without dedupe this would write ~12-20 lines/second for as long as the user stays in the
    /// disabled app.
    private func noteCaptureSuppressed(for application: NSRunningApplication) {
        let bundleIdentifier = application.bundleIdentifier
        guard lastSuppressedBundleIdentifier != bundleIdentifier else {
            return
        }
        lastSuppressedBundleIdentifier = bundleIdentifier
        let name = application.localizedName ?? "?"
        let id = bundleIdentifier ?? "no bundle id"
        CotabbyLogger.focus.info("Focus capture suppressed for \(name) (\(id))")
    }

    private func noteCaptureResumedIfNeeded() {
        guard lastSuppressedBundleIdentifier != nil else {
            return
        }
        lastSuppressedBundleIdentifier = nil
        CotabbyLogger.focus.info("Focus capture resumed")
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
