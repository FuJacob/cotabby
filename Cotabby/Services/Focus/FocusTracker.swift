import AppKit
import ApplicationServices
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
    /// Retained only so debug instrumentation can read cache hit/miss counts; resolution itself goes
    /// through `snapshotResolver`, which shares this same instance.
    private let caretGeometryCache: CaretGeometrySourceCache?

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
        // The caret-geometry cache is owned here so its lifetime matches the tracker's; it memoizes
        // the focused field's text-run leaves so per-keystroke caret resolution can re-read them
        // instead of re-walking the AX tree.
        if let snapshotResolver {
            self.snapshotResolver = snapshotResolver
            self.caretGeometryCache = nil
        } else {
            let cache = CaretGeometrySourceCache()
            self.snapshotResolver = FocusSnapshotResolver(caretGeometryCache: cache)
            self.caretGeometryCache = cache
        }
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

        guard let focusedElement = AXHelper.focusedElement() else {
            let frontmost = NSWorkspace.shared.frontmostApplication
            if let frontmost {
                AXChromeFocusProbe.dumpIfNeeded(
                    application: frontmost,
                    systemFocusedElement: nil,
                    snapshot: nil,
                    reason: "system-wide AXFocusedUIElement was nil"
                )
            }
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
        guard let application = AXHelper.owningApplication(of: focusedElement)
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
            AXChromeFocusProbe.dumpIfNeeded(
                application: application,
                systemFocusedElement: focusedElement,
                snapshot: firstPassSnapshot,
                reason: "resolver produced no focused input context"
            )
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
        AXChromeFocusProbe.dumpIfNeeded(
            application: application,
            systemFocusedElement: focusedElement,
            snapshot: finalSnapshot,
            reason: "focused input snapshot changed"
        )
        return FocusCaptureResult(snapshot: finalSnapshot, didChangeFocusedInput: true)
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
        let stats = caretGeometryCache?.debugStats ?? "no-cache"
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

/// Temporary Chrome-only AX probe for the Gmail/Claude focus investigation.
///
/// The normal resolver intentionally starts from the focused element and walks a small local
/// neighborhood. This probe exists to test a different question: when Chromium reports toolbar focus
/// or no global focus, does the live editor selection still exist elsewhere under Chrome's app/window
/// AX tree? It requires both `-cotabby-debug` and `-cotabby-ax-probe`, is throttled, and logs
/// bounded structural metadata rather than unbounded page text.
@MainActor
private enum AXChromeFocusProbe {
    private static let supportedBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser"
    ]
    private static let probeArgument = "-cotabby-ax-probe"
    private static let searchArgument = "-cotabby-ax-probe-search"
    private static let maxAncestorDepth = 12
    private static let maxScanDepth = 28
    private static let maxScanNodes = 2_500
    private static let maxHighlightLines = 90
    private static let minRepeatInterval: TimeInterval = 3

    private static var lastSignature: String?
    private static var lastDumpAt: Date?

    static func dumpIfNeeded(
        application: NSRunningApplication,
        systemFocusedElement: AXUIElement?,
        snapshot: FocusSnapshot?,
        reason: String
    ) {
        guard CotabbyDebugOptions.isEnabled else { return }
        guard ProcessInfo.processInfo.arguments.contains(probeArgument) else { return }
        guard
            let bundleIdentifier = application.bundleIdentifier,
            supportedBundleIdentifiers.contains(bundleIdentifier)
        else {
            return
        }

        let appElement = AXHelper.applicationElement(processIdentifier: application.processIdentifier)
        let appFocusedElement = AXHelper.focusedElement(inApplication: appElement)
        let focusedWindow = AXHelper.uiElementValue(for: kAXFocusedWindowAttribute as CFString, on: appElement)
        let signature = [
            bundleIdentifier,
            reason,
            snapshot?.capability.summary ?? "no-snapshot",
            systemFocusedElement.map(AXHelper.elementIdentity) ?? "system-nil",
            appFocusedElement.map(AXHelper.elementIdentity) ?? "app-nil",
            focusedWindow.map(AXHelper.elementIdentity) ?? "window-nil",
            contextSignature(snapshot?.context)
        ].joined(separator: "|")

        let now = Date()
        if signature == lastSignature,
           let lastDumpAt,
           now.timeIntervalSince(lastDumpAt) < minRepeatInterval {
            return
        }

        lastSignature = signature
        lastDumpAt = now

        let searchHint = configuredSearchHint()
        var lines: [String] = []
        lines.append("========== CHROME AX FOCUS PROBE ==========")
        lines.append("reason=\(reason)")
        lines.append("app=\(application.localizedName ?? "Unknown") bundle=\(bundleIdentifier) pid=\(application.processIdentifier)")
        lines.append("snapshot=\(snapshotSummary(snapshot))")
        if let searchHint {
            lines.append("searchHint=\"\(sanitize(searchHint, limit: 80))\"")
        }

        lines.append("-- system AXFocusedUIElement --")
        appendElementBlock(systemFocusedElement, searchHint: searchHint, to: &lines)
        lines.append("-- app AXFocusedUIElement --")
        appendElementBlock(appFocusedElement, searchHint: searchHint, to: &lines)
        lines.append("-- app AXFocusedWindow --")
        appendElementBlock(focusedWindow, searchHint: searchHint, to: &lines)

        appendAncestorBlock(
            title: "-- system focus ancestors --",
            root: systemFocusedElement,
            searchHint: searchHint,
            to: &lines
        )
        appendAncestorBlock(
            title: "-- app focus ancestors --",
            root: appFocusedElement,
            searchHint: searchHint,
            to: &lines
        )

        let scanRoots = uniqueRoots([
            ("system-focus", systemFocusedElement),
            ("app-focus", appFocusedElement),
            ("focused-window", focusedWindow),
            ("app-root", appElement)
        ])
        for root in scanRoots {
            appendDeepScanBlock(root: root, searchHint: searchHint, to: &lines)
        }

        lines.append("========== END CHROME AX FOCUS PROBE ==========")
        CotabbyLogger.focus.debug("\(lines.joined(separator: "\n"))")
    }

    private static func contextSignature(_ context: FocusedInputSnapshot?) -> String {
        guard let context else { return "context-nil" }
        return [
            context.role,
            context.subrole ?? "n/a",
            "\(context.selection.location)+\(context.selection.length)",
            "\(context.precedingText.count)+\(context.trailingText.count)",
            formatRect(context.caretRect),
            context.inputFrameRect.map(formatRect) ?? "input-nil"
        ].joined(separator: "/")
    }

    private static func snapshotSummary(_ snapshot: FocusSnapshot?) -> String {
        guard let snapshot else { return "nil" }
        guard let context = snapshot.context else {
            return "\(snapshot.capability.shortLabel) reason=\"\(snapshot.capability.summary)\""
        }

        let textLength = context.precedingText.count + context.trailingText.count
        return "\(snapshot.capability.shortLabel) role=\(context.role)/\(context.subrole ?? "n/a") "
            + "selection=\(context.selection.location)+\(context.selection.length) "
            + "textLength=\(textLength) caret=\(context.caretQuality.label):\(context.caretSource) "
            + "caretRect=\(formatRect(context.caretRect)) inputRect=\(context.inputFrameRect.map(formatRect) ?? "nil")"
    }

    private static func appendElementBlock(
        _ element: AXUIElement?,
        searchHint: String?,
        to lines: inout [String]
    ) {
        guard let element else {
            lines.append("  nil")
            return
        }

        lines.append("  \(describe(element, searchHint: searchHint))")
    }

    private static func appendAncestorBlock(
        title: String,
        root: AXUIElement?,
        searchHint: String?,
        to lines: inout [String]
    ) {
        lines.append(title)
        guard let root else {
            lines.append("  nil")
            return
        }

        var current: AXUIElement? = root
        for depth in 0..<maxAncestorDepth {
            guard let element = current else { return }
            lines.append("  [\(depth)] \(describe(element, searchHint: searchHint))")
            current = AXHelper.parentElement(of: element)
        }
    }

    private static func appendDeepScanBlock(
        root: ProbeRoot,
        searchHint: String?,
        to lines: inout [String]
    ) {
        lines.append("-- deep scan: \(root.label) --")

        var queue: [(element: AXUIElement, path: String, depth: Int)] = [
            (root.element, rolePathComponent(root.element), 0)
        ]
        var seen = Set<String>()
        var visited = 0
        var highlights: [String] = []

        while !queue.isEmpty, visited < maxScanNodes {
            let item = queue.removeFirst()
            let identity = AXHelper.elementIdentity(for: item.element)
            guard seen.insert(identity).inserted else { continue }
            visited += 1

            if let highlight = highlightLine(for: item.element, path: item.path, searchHint: searchHint) {
                highlights.append(highlight)
                if highlights.count >= maxHighlightLines {
                    break
                }
            }

            guard item.depth < maxScanDepth else { continue }
            for child in AXHelper.childElements(of: item.element) {
                let path = "\(item.path) > \(rolePathComponent(child))"
                queue.append((child, path, item.depth + 1))
            }
        }

        lines.append("  visited=\(visited) highlights=\(highlights.count)")
        if highlights.isEmpty {
            lines.append("  no selected/text-marker/value/web nodes found within scan budget")
        } else {
            lines.append(contentsOf: highlights.map { "  \($0)" })
        }
    }

    private static func highlightLine(
        for element: AXUIElement,
        path: String,
        searchHint: String?
    ) -> String? {
        let attributes = Set(AXHelper.attributeNames(on: element))
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "Unknown"
        let value = attributes.contains(kAXValueAttribute as String)
            ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
            : nil
        let hasSelection = attributes.contains(kAXSelectedTextRangeAttribute as String)
        let hasMarker = attributes.contains("AXSelectedTextMarkerRange")
        let matchesHint = searchHint.flatMap { hint in
            value?.range(of: hint, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? nil : true
        } ?? false
        let isImportantRole = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXStaticTextRole as String,
            "AXWebArea",
            "AXSearchField"
        ].contains(role)

        guard hasSelection || hasMarker || matchesHint || isImportantRole else {
            return nil
        }

        var parts: [String] = [path, describe(element, searchHint: searchHint)]
        if matchesHint {
            parts.append("MATCHED_SEARCH_HINT")
        }
        return parts.joined(separator: " | ")
    }

    private static func describe(_ element: AXUIElement, searchHint: String?) -> String {
        let attributes = Set(AXHelper.attributeNames(on: element))
        let parameterizedAttributes = Set(AXHelper.parameterizedAttributeNames(on: element))
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "Unknown"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        let title = AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element)
        let description = AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)
        let value = attributes.contains(kAXValueAttribute as String)
            ? AXHelper.stringValue(for: kAXValueAttribute as CFString, on: element)
            : nil
        let selection = attributes.contains(kAXSelectedTextRangeAttribute as String)
            ? AXHelper.rangeValue(for: kAXSelectedTextRangeAttribute as CFString, on: element)
            : nil
        let markerRect = attributes.contains("AXSelectedTextMarkerRange")
            ? AXHelper.textMarkerCaretRect(on: element)
            : nil
        let frame = attributes.contains("AXFrame")
            ? AXHelper.rectValue(for: "AXFrame" as CFString, on: element)
            : nil
        let children = AXHelper.childElements(of: element).count

        var parts: [String] = ["role=\(role)/\(subrole ?? "n/a")"]
        parts.append("id=\(AXHelper.elementIdentity(for: element))")
        if let title, !title.isEmpty {
            parts.append("title=\"\(sanitize(title, limit: 60))\"")
        }
        if let description, !description.isEmpty {
            parts.append("description=\"\(sanitize(description, limit: 60))\"")
        }
        if let frame {
            parts.append("frame=\(formatRect(frame))")
            parts.append("cocoaFrame=\(formatRect(AXHelper.cocoaRect(fromAccessibilityRect: frame)))")
        }
        if let selection {
            parts.append("selection=\(selection.location)+\(selection.length)")
        }
        if attributes.contains("AXSelectedTextMarkerRange") {
            parts.append("selectedMarker=true")
        }
        if let markerRect, !markerRect.isEmpty {
            parts.append("markerRect=\(formatRect(markerRect))")
        }
        if parameterizedAttributes.contains(kAXBoundsForRangeParameterizedAttribute as String) {
            parts.append("boundsForRange=true")
        }
        if let editable = AXHelper.boolValue(for: "AXEditable" as CFString, on: element) {
            parts.append("editable=\(editable)")
        }
        if let numberOfCharacters = AXHelper.copyAttributeValue("AXNumberOfCharacters" as CFString, on: element) as? NSNumber {
            parts.append("characters=\(numberOfCharacters.intValue)")
        }
        if let value {
            parts.append("valueLen=\(value.count)")
            if valueMatchesSearchHint(value, searchHint: searchHint) {
                parts.append("valuePreview=\"\(sanitize(value, limit: 80))\"")
            }
        }
        if children > 0 {
            parts.append("children=\(children)")
        }

        return parts.joined(separator: " ")
    }

    private static func valueMatchesSearchHint(_ value: String, searchHint: String?) -> Bool {
        guard let searchHint, !searchHint.isEmpty else {
            return false
        }

        return value.range(of: searchHint, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func rolePathComponent(_ element: AXUIElement) -> String {
        let role = AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) ?? "?"
        let subrole = AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element)
        if let subrole {
            return "\(role)(\(subrole))"
        }

        return role
    }

    private static func uniqueRoots(_ roots: [(String, AXUIElement?)]) -> [ProbeRoot] {
        var seen = Set<String>()
        var result: [ProbeRoot] = []
        for (label, element) in roots {
            guard let element else { continue }
            let identity = AXHelper.elementIdentity(for: element)
            guard seen.insert(identity).inserted else { continue }
            result.append(ProbeRoot(label: label, element: element))
        }
        return result
    }

    private static func configuredSearchHint() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: searchArgument) else {
            return nil
        }

        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else {
            return nil
        }

        let value = arguments[valueIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func sanitize(_ text: String, limit: Int) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        if compact.count <= limit {
            return compact
        }

        return "\(compact.prefix(limit))..."
    }

    private static func formatRect(_ rect: CGRect) -> String {
        String(
            format: "(x=%.0f,y=%.0f,w=%.0f,h=%.0f)",
            rect.origin.x,
            rect.origin.y,
            rect.width,
            rect.height
        )
    }

    private struct ProbeRoot {
        let label: String
        let element: AXUIElement
    }
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
