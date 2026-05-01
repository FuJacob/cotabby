import AppKit
import ApplicationServices
import Foundation

/// File overview:
/// Observes Accessibility focus notifications and publishes the latest `FocusSnapshot`.
///
/// `FocusTracker` uses a hybrid strategy: AX notifications trigger immediate refreshes, while a
/// 100 ms polling loop covers host apps that fail to deliver every observer notification. AX
/// candidate resolution lives in `FocusSnapshotResolver`, and caret/frame heuristics live in
/// `AXTextGeometryResolver`.
nonisolated private let focusTrackerObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else {
        return
    }

    let notificationName = notification as String
    let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in
        tracker.handleAXNotification(named: notificationName)
    }
}

@MainActor
final class FocusTracker {
    private enum AXNotificationSet {
        static let application: [CFString] = [
            kAXFocusedUIElementChangedNotification as CFString,
            kAXFocusedWindowChangedNotification as CFString,
            kAXApplicationDeactivatedNotification as CFString,
        ]

        static let focusedElement: [CFString] = [
            kAXValueChangedNotification as CFString,
            kAXSelectedTextChangedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
        ]
    }

    var onSnapshotChange: ((FocusSnapshot) -> Void)?
    /// Debug hook for raw AX notification hits. The tracker still publishes snapshots separately
    /// because several notifications can collapse into the same resolved focus state.
    var onAXNotification: ((String) -> Void)?

    private(set) var snapshot: FocusSnapshot = .inactive {
        didSet {
            guard oldValue != snapshot else {
                return
            }

            onSnapshotChange?(snapshot)
        }
    }

    private let permissionProvider: @MainActor () -> Bool
    private let ignoredBundleIdentifier: String?
    private let snapshotResolver: FocusSnapshotResolver

    private var observer: AXObserver?
    private var observedApplicationElement: AXUIElement?
    private var observedFocusedElement: AXUIElement?
    private var observedApplicationPID: pid_t?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var pollingRefreshTask: Task<Void, Never>?

    /// Monotonic counter that increments every time a focus-changing AX notification fires or
    /// polling discovers a focused field switch that AX missed.
    ///
    /// AX element identity is based on `CFHash`, which macOS can recycle across unrelated
    /// elements. This counter gives downstream consumers a guaranteed-unique signal that
    /// focus actually changed, independent of hash collisions. Value and selection changes
    /// within the same field do not bump it.
    private var focusChangeSequence: UInt64 = 0

    init(
        permissionProvider: @escaping @MainActor () -> Bool,
        ignoredBundleIdentifier: String?,
        snapshotResolver: FocusSnapshotResolver? = nil,
        diagnosticsLogger: (any DiagnosticsLogging)? = nil
    ) {
        self.permissionProvider = permissionProvider
        self.ignoredBundleIdentifier = ignoredBundleIdentifier
        // Default resolver construction must happen inside the actor-isolated initializer body.
        // Swift evaluates default parameter expressions before entering the `@MainActor` context.
        self.snapshotResolver = snapshotResolver ?? FocusSnapshotResolver(
            diagnosticsLogger: diagnosticsLogger
        )
    }

    /// Starts hybrid focus observation and immediately captures an initial snapshot.
    func start() {
        guard workspaceActivationObserver == nil else {
            startPollingRefreshLoop()
            refreshNow()
            return
        }

        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Switching apps is always a focus change.
                self?.focusChangeSequence += 1
                self?.refreshNow()
            }
        }

        // The initial observation counts as a focus change so the first snapshot always
        // carries a non-zero sequence, distinguishing it from the default 0.
        focusChangeSequence += 1
        refreshNow()
        startPollingRefreshLoop()
    }

    /// Stops event observation while leaving the most recent snapshot available to callers.
    func stop() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil
        pollingRefreshTask?.cancel()
        pollingRefreshTask = nil

        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }

        clearAXObserver()
    }

    /// Performs a synchronous snapshot capture outside the normal notification cadence.
    func refreshNow() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil

        var capture = captureSnapshot()
        if didFocusedContextChangeByPolling(from: snapshot.context, to: capture.snapshot.context) {
            focusChangeSequence += 1
            capture = captureSnapshot()
        }

        snapshot = capture.snapshot

        if let focusedElement = capture.focusedElement {
            registerFocusedElementNotifications(on: focusedElement)
        } else {
            clearFocusedElementNotifications()
        }
    }

    fileprivate func handleAXNotification(named notificationName: String) {
        onAXNotification?(notificationName)

        // Only focus-changing notifications bump the sequence. Value/selection changes within
        // the same field should not, because the visual-context coordinator uses this counter
        // to decide whether to start a new OCR session.
        let focusChangingNotifications: Set<String> = [
            kAXFocusedUIElementChangedNotification as String,
            kAXFocusedWindowChangedNotification as String,
            kAXApplicationDeactivatedNotification as String,
        ]
        if focusChangingNotifications.contains(notificationName) {
            focusChangeSequence += 1
        }

        if notificationName == kAXApplicationDeactivatedNotification as String {
            scheduleRefresh(after: 0)
            return
        }

        scheduleRefresh(after: 0)
    }

    private func startPollingRefreshLoop() {
        guard pollingRefreshTask == nil else {
            return
        }

        pollingRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else {
                    return
                }

                self?.refreshNow()
            }
        }
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task { [weak self] in
            guard delay > 0 else {
                self?.refreshNow()
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }

            self?.refreshNow()
        }
    }

    /// Captures the current frontmost application's focused element and reduces it into a snapshot.
    private func captureSnapshot() -> FocusCaptureResult {
        guard permissionProvider() else {
            clearAXObserver()
            return FocusCaptureResult(
                snapshot: FocusSnapshot(
                    applicationName: "Accessibility permission missing",
                    bundleIdentifier: nil,
                    capability: .blocked("Accessibility permission is required."),
                    context: nil,
                    inspection: nil
                )
            )
        }

        guard let application = NSWorkspace.shared.frontmostApplication else {
            clearAXObserver()
            return FocusCaptureResult(
                snapshot: FocusSnapshot(
                    applicationName: "No active application",
                    bundleIdentifier: nil,
                    capability: .unsupported("No active application."),
                    context: nil,
                    inspection: nil
                )
            )
        }

        if application.bundleIdentifier == ignoredBundleIdentifier {
            clearAXObserver()
            return FocusCaptureResult(
                snapshot: FocusSnapshot(
                    applicationName: application.localizedName ?? "Tabby",
                    bundleIdentifier: application.bundleIdentifier,
                    capability: .blocked("Tabby is focused."),
                    context: nil,
                    inspection: nil
                )
            )
        }

        configureAXObserver(for: application)

        guard let focusedElement = AXHelper.focusedElement() else {
            return FocusCaptureResult(
                snapshot: FocusSnapshot(
                    applicationName: application.localizedName ?? "Unknown",
                    bundleIdentifier: application.bundleIdentifier,
                    capability: .unsupported("No focused Accessibility element."),
                    context: nil,
                    inspection: nil
                )
            )
        }

        return FocusCaptureResult(
            snapshot: snapshotResolver.resolveSnapshot(
                focusedElement: focusedElement,
                application: application,
                focusChangeSequence: focusChangeSequence
            ),
            focusedElement: focusedElement
        )
    }

    private func configureAXObserver(for application: NSRunningApplication) {
        let pid = application.processIdentifier
        guard observer == nil || observedApplicationPID != pid else {
            return
        }

        clearAXObserver()

        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, focusTrackerObserverCallback, &newObserver)
        guard result == .success, let newObserver else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        observer = newObserver
        observedApplicationElement = applicationElement
        observedApplicationPID = pid

        let source = AXObserverGetRunLoopSource(newObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        for notification in AXNotificationSet.application {
            addNotification(notification, to: applicationElement)
        }
    }

    private func registerFocusedElementNotifications(on focusedElement: AXUIElement) {
        guard observer != nil else {
            return
        }

        if let observedFocusedElement,
           AXHelper.elementIdentity(for: observedFocusedElement) == AXHelper.elementIdentity(for: focusedElement)
        {
            return
        }

        clearFocusedElementNotifications()
        observedFocusedElement = focusedElement

        for notification in AXNotificationSet.focusedElement {
            addNotification(notification, to: focusedElement)
        }
    }

    private func clearFocusedElementNotifications() {
        guard let observer, let observedFocusedElement else {
            self.observedFocusedElement = nil
            return
        }

        for notification in AXNotificationSet.focusedElement {
            AXObserverRemoveNotification(observer, observedFocusedElement, notification)
        }

        self.observedFocusedElement = nil
    }

    private func clearAXObserver() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil

        clearFocusedElementNotifications()

        if let observer {
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        observer = nil
        observedApplicationElement = nil
        observedApplicationPID = nil
    }

    @discardableResult
    private func addNotification(_ notification: CFString, to element: AXUIElement) -> Bool {
        guard let observer else {
            return false
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(observer, element, notification, refcon)
        return result == .success || result == .notificationAlreadyRegistered
    }

    /// Polling can discover a new focused field even when the host app never delivered the
    /// corresponding AX notification. When that happens, bump the sequence so downstream
    /// field-scoped work, especially OCR sessions, can distinguish the new focus owner.
    private func didFocusedContextChangeByPolling(
        from previousContext: FocusedInputSnapshot?,
        to nextContext: FocusedInputSnapshot?
    ) -> Bool {
        guard let previousContext, let nextContext else {
            return false
        }

        return previousContext.bundleIdentifier != nextContext.bundleIdentifier
            || previousContext.processIdentifier != nextContext.processIdentifier
            || previousContext.elementIdentifier != nextContext.elementIdentifier
    }
}

private struct FocusCaptureResult {
    let snapshot: FocusSnapshot
    let focusedElement: AXUIElement?

    init(snapshot: FocusSnapshot, focusedElement: AXUIElement? = nil) {
        self.snapshot = snapshot
        self.focusedElement = focusedElement
    }
}
