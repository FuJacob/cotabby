import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Owns the global keyboard event taps used to detect typing, navigation, dismissal keys,
/// and `Tab` acceptance. This is the boundary between raw CGEvents and Cotabby's smaller
/// input-event vocabulary.
///
/// `CapturedInputEvent` now lives in `Models/InputModels.swift` so the rest of the app can depend
/// on the semantic event type without importing this event-tap implementation.

/// Installs two taps:
/// - A steady-state `.listenOnly` observer at the head of the chain. Listen-only taps do not gate
///   event delivery on the callback's return, so a slow main actor cannot stall global keystrokes
///   in unrelated apps (DaVinci Resolve's Spacebar play/pause — see issue #328).
/// - An active `.defaultTap` accept tap that runs on a dedicated background thread, so a busy main
///   run loop (Chromium AX polling, SwiftUI updates, suggestion debouncing) can never delay or
///   drop keystrokes. Tap presence is gated on a lock-protected `AcceptInterceptionState` — when
///   the coordinator is not actively accepting, the callback reads `isAccepting == false` and
///   passes every key through without touching the main actor.
///
/// The previous design hopped to `MainActor.assumeIsolated` for every keydown the active tap saw.
/// That was correct in steady state but became acute after #379 added a synchronous AX walk on the
/// keystroke critical path: when the AX walk took 200–500 ms (Chrome contenteditable, Console,
/// Xcode), the tap callback queued behind it and macOS either delayed or dropped the keystroke.
/// Moving the active callback off the main run loop entirely closes that race for good.
@MainActor
final class InputMonitor {
    var onEvent: ((CapturedInputEvent) -> Bool)?
    var onSuppressedSyntheticInput: (() -> Void)?

    /// Reads the current word-accept key code from the model at event time. Still used by the
    /// observer-tap classification (which runs on the main actor), and by `syncAcceptSnapshot`
    /// to refresh the lock-protected snapshot the background accept tap reads.
    var acceptanceKeyCodeProvider: @MainActor () -> CGKeyCode = { 48 } {
        didSet { syncAcceptSnapshot() }
    }

    var acceptanceKeyModifiersProvider: @MainActor () -> ShortcutModifierMask = { [] } {
        didSet { syncAcceptSnapshot() }
    }

    var fullAcceptanceKeyCodeProvider: @MainActor () -> CGKeyCode = { CGKeyCode(UInt16.max) } {
        didSet { syncAcceptSnapshot() }
    }

    var fullAcceptanceKeyModifiersProvider: @MainActor () -> ShortcutModifierMask = { [] } {
        didSet { syncAcceptSnapshot() }
    }

    var shouldProcessEventsProvider: @MainActor () -> Bool = { true } {
        didSet { syncAcceptSnapshot() }
    }

    private let permissionProvider: @MainActor () -> Bool
    private let suppressionController: InputSuppressionController

    private var observerTap: CFMachPort?
    private var observerRunLoopSource: CFRunLoopSource?

    private var acceptTap: CFMachPort?
    private var acceptRunLoopSource: CFRunLoopSource?
    private var acceptTapThread: Thread?

    /// Lock-protected snapshot read by the active accept tap from a background thread. Lives on
    /// the heap with its own `NSLock` so it is straightforwardly thread-safe without involving
    /// the main actor on the keystroke critical path. The coordinator pushes updates here whenever
    /// it activates / deactivates interception or whenever the accept-key binding changes.
    nonisolated let acceptInterceptionState = AcceptInterceptionState()

    init(
        permissionProvider: @escaping @MainActor () -> Bool,
        suppressionController: InputSuppressionController
    ) {
        self.permissionProvider = permissionProvider
        self.suppressionController = suppressionController
    }

    /// Installs the observer tap and begins listening for global keyboard activity.
    func start() {
        CotabbyLogger.app.info("Input monitor starting")
        refresh()
    }

    /// Removes both taps and stops observing keyboard events.
    func stop() {
        CotabbyLogger.app.info("Input monitor stopping")
        destroyAcceptTap()
        destroyObserverTap()
    }

    /// Re-evaluates whether the observer tap should exist after a permission change.
    /// The accept tap is also torn down if permission was revoked; it gets re-installed lazily
    /// the next time the coordinator activates interception.
    func refresh() {
        if permissionProvider() {
            installObserverTapIfNeeded()
        } else {
            destroyAcceptTap()
            destroyObserverTap()
            acceptInterceptionState.update(isAccepting: false)
        }
    }

    /// Toggles whether the background accept tap will consume keystrokes that match the configured
    /// accept-key bindings. The coordinator calls this on every overlay-state change.
    ///
    /// The tap itself is installed lazily on first activation and then stays alive on its
    /// background thread for the rest of the session — the gating is purely the `isAccepting` flag
    /// in the lock-protected snapshot. Keeping the tap alive avoids CFMachPort / thread churn on
    /// every overlay show, and because the callback runs on a background thread none of this
    /// touches main-run-loop work.
    func setAcceptInterceptionActive(_ active: Bool) {
        guard permissionProvider() else {
            acceptInterceptionState.update(isAccepting: false)
            return
        }
        syncAcceptSnapshot(isAcceptingOverride: active)
        if active {
            installAcceptTapIfNeeded()
        }
    }

    /// Re-posts an accept key that was already swallowed by the active tap. The coordinator only
    /// calls this from the bail paths in `acceptSuggestion` — by which point the overlay has been
    /// hidden (so `isAccepting` is false in the snapshot) and the synthetic event we post will
    /// reach the focused application unmodified. Suppression is armed beforehand so our own
    /// observer tap recognizes the replay as Cotabby's own work instead of treating it as a fresh
    /// user keystroke.
    func replayConsumedAcceptKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            CotabbyLogger.app.warning("Failed to synthesize replay for consumed accept key \(keyCode)")
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        CotabbyLogger.app.debug("Replayed consumed accept key \(keyCode) to the focused app")
    }

    /// Pushes the latest accept-key bindings + per-app gate into the lock-protected snapshot so
    /// the background tap callback sees them on the very next keydown. Called from the property
    /// observers above and from `setAcceptInterceptionActive`.
    private func syncAcceptSnapshot(isAcceptingOverride: Bool? = nil) {
        let acceptKey = acceptanceKeyCodeProvider()
        let acceptMods = acceptanceKeyModifiersProvider()
        let fullKey = fullAcceptanceKeyCodeProvider()
        let fullMods = fullAcceptanceKeyModifiersProvider()
        let shouldProcess = shouldProcessEventsProvider()
        acceptInterceptionState.update(
            isAccepting: isAcceptingOverride,
            shouldProcess: shouldProcess,
            acceptKey: acceptKey,
            acceptModifiers: acceptMods,
            fullAcceptKey: fullKey,
            fullAcceptModifiers: fullMods
        )
    }

    private func installObserverTapIfNeeded() {
        guard observerTap == nil else {
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                monitor.handleObserverTap(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            CotabbyLogger.app.warning("Failed to create CGEvent observer tap — Input Monitoring permission may be missing")
            return
        }
        CotabbyLogger.app.info("CGEvent observer tap installed (listen-only)")

        observerTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        observerRunLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installAcceptTapIfNeeded() {
        guard acceptTap == nil else {
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            // Background-thread call — *do not* hop to MainActor here. The whole point of this
            // tap living on a dedicated thread is to return in microseconds regardless of main-
            // run-loop load. The callback reads only the lock-protected `AcceptInterceptionState`.
            let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.acceptTapCallback(type: type, event: event)
        }

        // Tail-append so this tap runs *after* the head-inserted observer.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            CotabbyLogger.app.warning("Failed to create CGEvent accept tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        acceptTap = tap
        acceptRunLoopSource = source

        // Dedicated background thread. The callback runs on its run loop, completely independent of
        // the main run loop. Even when the main actor is saturated with AX walks or SwiftUI work,
        // event delivery to other apps is never gated on Cotabby's work.
        let thread = Thread { [source, tap] in
            let runLoop = CFRunLoopGetCurrent()
            if let source {
                CFRunLoopAddSource(runLoop, source, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            // Block forever; the only way out is `stop()` invalidating the Mach port from the main
            // actor, which causes CFRunLoopRun to return.
            CFRunLoopRun()
        }
        thread.name = "co.cotabby.accept-tap"
        thread.qualityOfService = .userInteractive
        acceptTapThread = thread
        thread.start()

        CotabbyLogger.app.info("CGEvent accept tap installed on dedicated background thread")
    }

    private func destroyObserverTap() {
        if let source = observerRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        observerRunLoopSource = nil

        if let tap = observerTap {
            CFMachPortInvalidate(tap)
        }
        observerTap = nil
    }

    private func destroyAcceptTap() {
        guard acceptTap != nil || acceptRunLoopSource != nil else {
            return
        }
        acceptInterceptionState.update(isAccepting: false)
        if let tap = acceptTap {
            CFMachPortInvalidate(tap)
        }
        acceptTap = nil
        acceptRunLoopSource = nil
        acceptTapThread = nil
        CotabbyLogger.app.info("CGEvent accept tap removed")
    }

    /// Listen-only observer: classifies the event and notifies the coordinator. The return value
    /// of `onEvent` is ignored here because a listen-only tap cannot drop or modify events.
    /// Consumption of the accept key is handled by the separate background accept tap.
    private func handleObserverTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            CotabbyLogger.app.warning("Observer tap was disabled by system, re-enabling")
            if let observerTap {
                CGEvent.tapEnable(tap: observerTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if suppressionController.consumeIfNeeded() {
                onSuppressedSyntheticInput?()
                return Unmanaged.passUnretained(event)
            }

            guard shouldProcessEventsProvider() else {
                return Unmanaged.passUnretained(event)
            }

            let capturedEvent = classify(event: event)
            _ = onEvent?(capturedEvent)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Background-thread callback. Reads the lock-protected snapshot and returns in microseconds.
    /// No main-actor hop, no shared mutable state outside the lock. Fail-open: if the snapshot
    /// says we are not actively accepting, every key passes through untouched.
    nonisolated private func acceptTapCallback(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // We can't re-enable from this thread without main-actor access to `acceptTap`. Hop
            // there asynchronously. Until re-enable completes the tap is dormant — which fails
            // open, exactly the behavior we want.
            CotabbyLogger.app.warning("Accept tap was disabled by system, scheduling re-enable")
            Task { @MainActor [weak self] in
                guard let self, let tap = self.acceptTap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let snapshot = acceptInterceptionState.snapshot()
            guard snapshot.isAccepting, snapshot.shouldProcess else {
                return Unmanaged.passUnretained(event)
            }
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let eventModifiers = ShortcutModifierMask(eventFlags: event.flags)
            let acceptMatches = keyCode == snapshot.acceptKey
                && eventModifiers == snapshot.acceptModifiers
            let fullAcceptMatches = keyCode == snapshot.fullAcceptKey
                && eventModifiers == snapshot.fullAcceptModifiers
            if acceptMatches || fullAcceptMatches {
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Reduces a raw CGEvent into the smaller event categories the suggestion coordinator understands.
    private func classify(event: CGEvent) -> CapturedInputEvent {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let characters = event.unicodeString

        let noModifiers = flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate, .maskShift])

        let fullAcceptKey = fullAcceptanceKeyCodeProvider()
        let acceptKey = acceptanceKeyCodeProvider()

        if keyCode == fullAcceptKey, noModifiers {
            return CapturedInputEvent(kind: .fullAcceptance, keyCode: keyCode, characters: characters, flags: flags)
        }

        if keyCode == acceptKey, noModifiers {
            return CapturedInputEvent(kind: .acceptance, keyCode: keyCode, characters: characters, flags: flags)
        }

        if [123, 124, 125, 126].contains(keyCode) {
            return CapturedInputEvent(kind: .navigation, keyCode: keyCode, characters: characters, flags: flags)
        }

        if [51, 117, 36, 76].contains(keyCode) {
            return CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: characters, flags: flags)
        }

        if keyCode == 53 {
            return CapturedInputEvent(kind: .dismissal, keyCode: keyCode, characters: characters, flags: flags)
        }

        if flags.contains(.maskCommand) {
            let mutationShortcutKeyCodes: Set<CGKeyCode> = [0, 6, 7, 9]
            let kind: CapturedInputEvent.Kind = mutationShortcutKeyCodes.contains(keyCode) ? .shortcutMutation : .dismissal
            return CapturedInputEvent(kind: kind, keyCode: keyCode, characters: characters, flags: flags)
        }

        if !characters.trimmingCharacters(in: .controlCharacters).isEmpty {
            return CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: characters, flags: flags)
        }

        return CapturedInputEvent(kind: .other, keyCode: keyCode, characters: characters, flags: flags)
    }
}

extension InputMonitor: SuggestionInputMonitoring {}

/// Heap-allocated, lock-protected mirror of the four values the background accept-tap callback
/// needs to make a consume decision: whether interception is active, whether the focused app is
/// gated, and the two configured accept-key bindings. Reads return a value snapshot so the
/// callback never holds the lock across event-system work.
final class AcceptInterceptionState {
    struct Snapshot: Sendable {
        let isAccepting: Bool
        let shouldProcess: Bool
        let acceptKey: CGKeyCode
        let acceptModifiers: ShortcutModifierMask
        let fullAcceptKey: CGKeyCode
        let fullAcceptModifiers: ShortcutModifierMask
    }

    private let lock = NSLock()
    private var isAccepting: Bool = false
    private var shouldProcess: Bool = true
    private var acceptKey: CGKeyCode = 48
    private var acceptModifiers: ShortcutModifierMask = []
    private var fullAcceptKey: CGKeyCode = CGKeyCode(UInt16.max)
    private var fullAcceptModifiers: ShortcutModifierMask = []

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            isAccepting: isAccepting,
            shouldProcess: shouldProcess,
            acceptKey: acceptKey,
            acceptModifiers: acceptModifiers,
            fullAcceptKey: fullAcceptKey,
            fullAcceptModifiers: fullAcceptModifiers
        )
    }

    func update(
        isAccepting: Bool? = nil,
        shouldProcess: Bool? = nil,
        acceptKey: CGKeyCode? = nil,
        acceptModifiers: ShortcutModifierMask? = nil,
        fullAcceptKey: CGKeyCode? = nil,
        fullAcceptModifiers: ShortcutModifierMask? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let isAccepting { self.isAccepting = isAccepting }
        if let shouldProcess { self.shouldProcess = shouldProcess }
        if let acceptKey { self.acceptKey = acceptKey }
        if let acceptModifiers { self.acceptModifiers = acceptModifiers }
        if let fullAcceptKey { self.fullAcceptKey = fullAcceptKey }
        if let fullAcceptModifiers { self.fullAcceptModifiers = fullAcceptModifiers }
    }
}

private extension CGEvent {
    var unicodeString: String {
        var length: Int = 0
        keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else {
            return ""
        }

        let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: length)
        defer {
            buffer.deallocate()
        }

        keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}
