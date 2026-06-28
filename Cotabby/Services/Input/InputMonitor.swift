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

/// Snapshot of the key data `InputMonitor` needs after a raw `CGEvent` enters the tap callback.
///
/// Keeping this as a tiny value type lets unit tests exercise tap ownership without constructing
/// synthetic CoreGraphics events. That matters because app-hosted macOS tests can crash in CGEvent
/// allocation/teardown even when the production code path is correct.
struct InputMonitorKeyEvent {
    let keyCode: CGKeyCode
    let characters: String
    let flags: CGEventFlags

    init(keyCode: CGKeyCode, characters: String = "", flags: CGEventFlags = []) {
        self.keyCode = keyCode
        self.characters = characters
        self.flags = flags
    }
}

/// The consuming tap has three possible outcomes for a key-down event.
///
/// `notHandled` means the key was not one of Cotabby's configured accept keys. `passThrough`
/// means it was an accept key but Cotabby declined to consume it. `consume` means the coordinator
/// accepted successfully and the original key event should be swallowed.
enum InputMonitorAcceptTapDecision: Equatable {
    case notHandled
    case passThrough
    case consume
}

/// Installs two taps:
/// - A steady-state `.listenOnly` observer at the head of the chain. Listen-only taps do not gate
///   event delivery on the callback's return, so a slow main actor cannot stall global keystrokes
///   in unrelated apps (DaVinci Resolve's Spacebar play/pause is the canonical victim of an active
///   tap here — see issue #328). It handles ordinary typing, navigation, and dismissal events.
/// - A narrow `.defaultTap` accept tap at the tail, installed only while a suggestion is visible.
///   This is the only path that consumes events, so it also owns acceptance side effects. Keeping
///   insertion and consumption in the same callback prevents the coordinator from hiding the overlay
///   before the tap has decided what to do with the original key.
@MainActor
final class InputMonitor {
    var onEvent: ((CapturedInputEvent) -> Bool)?
    var onSuppressedSyntheticInput: (() -> Void)?

    /// While an emoji capture session is active, the picker controller decides per key whether the
    /// active tap should swallow it (navigation, Return/Tab, Escape) or let it reach the field
    /// (query characters). `.notHandled` means no capture is active, so the accept tap falls through
    /// to its normal accept-key logic. The decision is computed by the observer pass for the same
    /// event, so this closure is a fast, side-effect-free read.
    var emojiCaptureKeyDecider: (@MainActor (InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision)?

    /// Reads the current word-accept binding (key code + required modifiers) from the model at event
    /// time, avoiding Combine delivery lag between settings changes and the event classifier. The two
    /// fields are returned together so a per-app override is scanned at most once per binding and the
    /// key code and its modifiers can never come from two different resolutions.
    var acceptanceBindingProvider: @MainActor () -> (keyCode: CGKeyCode, modifiers: ShortcutModifierMask) = {
        (48, [])
    }

    /// Reads the current full-accept binding (key code + required modifiers) from the model at event time.
    var fullAcceptanceBindingProvider: @MainActor () -> (keyCode: CGKeyCode, modifiers: ShortcutModifierMask) = {
        (CGKeyCode(UInt16.max), [])
    }

    /// Reads the global-toggle hotkey at event time. `disabledKeyCode` (UInt16.max) means unbound;
    /// the dedicated toggle tap is torn down whenever the provider returns that sentinel so users
    /// who never set the hotkey pay no per-keystroke cost.
    var globalToggleKeyCodeProvider: @MainActor () -> CGKeyCode = { CGKeyCode(UInt16.max) }

    /// Modifier mask required alongside the global-toggle hotkey. Empty means the bare key.
    var globalToggleKeyModifiersProvider: @MainActor () -> ShortcutModifierMask = { [] }

    /// Fired when a key event matches the configured global-toggle hotkey. Wired to flip the
    /// `isGloballyEnabled` setting; the keystroke is then consumed so the host app never sees it.
    var onGlobalToggleHotkey: (@MainActor () -> Void)?

    /// When false, the observer passes keystrokes through without classifying or notifying the
    /// coordinator. This eliminates per-keystroke overhead in apps where Cotabby will never act
    /// (terminals, globally disabled, per-app disabled).
    var shouldProcessEventsProvider: @MainActor () -> Bool = { true }

    /// Fail-open authorization for routing a matching accept key into the active accept tap.
    /// The tap still consumes only when the coordinator successfully accepts the event; this
    /// preflight keeps stale or misinstalled taps from even attempting acceptance.
    var shouldConsumeAcceptKeyProvider: @MainActor @Sendable () -> Bool = { false }

    private let permissionProvider: @MainActor () -> Bool
    private let suppressionController: InputSuppressionController

    private var observerTap: CFMachPort?
    private var observerRunLoopSource: CFRunLoopSource?

    private var acceptTap: CFMachPort?
    private var acceptRunLoopSource: CFRunLoopSource?

    /// Dedicated consuming tap for the global-toggle hotkey. Lives independently of the accept tap
    /// because it must fire even when no suggestion is visible — and even when Cotabby is globally
    /// disabled, since the whole purpose of the hotkey is to flip that switch back on.
    private var toggleTap: CFMachPort?
    private var toggleRunLoopSource: CFRunLoopSource?

    /// Tracks whether the consuming tap currently owns accept-key semantics. This is separate
    /// from "a suggestion exists": the observer should only suppress accept-key callbacks when a
    /// real default tap can make the consume/pass-through decision for that same physical key.
    ///
    /// Internal instead of private so unit tests can exercise observer routing without installing
    /// global event taps.
    var isAcceptTapOwningAcceptKeys = false

    /// The two independent reasons to keep the active tap installed. A visible suggestion needs to
    /// consume the accept key; an in-progress emoji capture needs to consume navigation and commit
    /// keys. Tracking them separately means neither feature removes the tap while the other still
    /// needs it, and the tap is gone entirely when both are idle (the issue #328 invariant).
    private var suggestionInterceptionActive = false
    /// Internal (not private) for the same reason as `isAcceptTapOwningAcceptKeys`: tests stage the
    /// "emoji capture open" state directly to exercise observer routing without installing real taps.
    /// Production only mutates this through `setCaptureInterceptionActive(_:)`.
    var captureInterceptionActive = false

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
        destroyToggleTap()
        destroyObserverTap()
    }

    /// Re-evaluates whether the observer tap should exist after a permission change.
    /// The accept tap is also torn down if permission was revoked; it gets re-installed lazily
    /// the next time the coordinator presents a suggestion.
    func refresh() {
        if permissionProvider() {
            installObserverTapIfNeeded()
            refreshToggleTap()
        } else {
            destroyAcceptTap()
            destroyToggleTap()
            destroyObserverTap()
        }
    }

    /// Installs or removes the global-toggle tap to match the current binding. Called by the
    /// environment whenever the user changes or clears the toggle hotkey, so the tap's lifetime
    /// tracks "binding exists" without paying for it when nothing is bound.
    func refreshToggleTap() {
        guard permissionProvider() else {
            destroyToggleTap()
            return
        }
        if globalToggleKeyCodeProvider() == Self.disabledKeyCode {
            destroyToggleTap()
        } else {
            installToggleTapIfNeeded()
        }
    }

    private static let disabledKeyCode: CGKeyCode = CGKeyCode(UInt16.max)

    /// How long the accept tap lingers (fail-open) after the overlay hides before its mach port is
    /// invalidated. A final-chunk accept runs *inside* this tap's own callback: it posts the
    /// synthetic insertion to `.cghidEventTap` and then hides the overlay, which routes back here to
    /// tear the tap down. Invalidating the mach port in that same run-loop turn pulls the tap out of
    /// the session tap chain before the just-posted synthetic keystroke drains through it, so the
    /// last accepted word never reaches the host (non-final words keep the overlay visible and never
    /// hit this path, which is why only the final word failed to commit). Deferring the invalidation
    /// one short hop lets the synthetic event finish delivery first. This is the invariant PR #385
    /// ("Fix last tab issue") protected before the two-tap ownership rewrite dropped it.
    private static let acceptTapTeardownDelaySeconds: TimeInterval = 0.05

    /// Suggestion-overlay reason for the active tap. The coordinator calls this when a suggestion
    /// becomes visible or hidden, so Cotabby only enters the synchronous event path while there is
    /// something to accept.
    func setAcceptInterceptionActive(_ active: Bool) {
        suggestionInterceptionActive = active
        updateAcceptTapState()
    }

    /// Emoji-capture reason for the active tap. The emoji controller calls this when a `:query`
    /// capture opens or closes, so the tap can consume navigation and commit keys for the duration.
    func setCaptureInterceptionActive(_ active: Bool) {
        captureInterceptionActive = active
        updateAcceptTapState()
    }

    /// Installs the active tap when either reason wants it and tears it down otherwise. Recomputes
    /// accept-key ownership: only a visible suggestion claims the accept key at the observer layer.
    /// When the tap exists solely for emoji capture, the observer must keep routing the accept key
    /// (Tab) to the coordinator so the emoji controller — not the suggestion accept path — acts on it.
    private func updateAcceptTapState() {
        let wantsTap = permissionProvider() && (suggestionInterceptionActive || captureInterceptionActive)
        // Only a visible suggestion claims the accept key at the observer layer. When the tap exists
        // solely for emoji capture, the observer must keep routing the accept key (Tab) to the
        // coordinator so the emoji controller — not the suggestion accept path — acts on it. Setting
        // this synchronously (even on teardown) lets the fail-open preflight resume passing keys
        // through immediately.
        isAcceptTapOwningAcceptKeys = wantsTap && suggestionInterceptionActive
        if wantsTap {
            installAcceptTapIfNeeded()
        } else {
            // Defer only the mach-port invalidation, so a final-chunk accept's synthetic insertion can
            // drain before the tap is removed (see `acceptTapTeardownDelaySeconds`). Re-check both
            // reasons at fire time so a suggestion or an emoji capture that re-armed the tap during the
            // delay keeps it installed.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.acceptTapTeardownDelaySeconds) { [weak self] in
                guard let self else { return }
                let stillWanted = self.permissionProvider()
                    && (self.suggestionInterceptionActive || self.captureInterceptionActive)
                guard !stillWanted else { return }
                self.destroyAcceptTap()
            }
        }
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
        // Ownership of the accept key is decided by `updateAcceptTapState`, not here, so this method
        // only guarantees the tap exists.
        guard acceptTap == nil else {
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                monitor.handleAcceptTap(type: type, event: event)
            }
        }

        // Tail-append so this tap runs *after* the head-inserted observer. The observer is
        // listen-only and intentionally ignores acceptance keys, so the default tap remains the
        // single place where accept insertion and original-key consumption are decided.
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
        CotabbyLogger.app.info("CGEvent accept tap installed (active, accept-key only)")

        acceptTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        acceptRunLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installToggleTapIfNeeded() {
        guard toggleTap == nil else {
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated {
                monitor.handleToggleTap(type: type, event: event)
            }
        }

        // Head-inserted so the toggle hotkey is decided before any other tap (including the accept
        // tap) gets a chance to consume the keystroke. The callback returns `nil` only when the
        // event matches the bound hotkey, so unrelated keys still drain through to the rest of the
        // chain in their normal order.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            CotabbyLogger.app.warning("Failed to create CGEvent toggle tap")
            return
        }
        CotabbyLogger.app.info("CGEvent toggle tap installed (active, toggle-hotkey only)")

        toggleTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        toggleRunLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
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
        isAcceptTapOwningAcceptKeys = false
        guard acceptTap != nil || acceptRunLoopSource != nil else {
            return
        }
        if let source = acceptRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        acceptRunLoopSource = nil

        if let tap = acceptTap {
            CFMachPortInvalidate(tap)
        }
        acceptTap = nil
        CotabbyLogger.app.info("CGEvent accept tap removed")
    }

    private func destroyToggleTap() {
        guard toggleTap != nil || toggleRunLoopSource != nil else {
            return
        }
        if let source = toggleRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        toggleRunLoopSource = nil

        if let tap = toggleTap {
            CFMachPortInvalidate(tap)
        }
        toggleTap = nil
        CotabbyLogger.app.info("CGEvent toggle tap removed")
    }

    /// Active toggle tap: consumes a keystroke only when it matches the configured global-toggle
    /// hotkey. The match is intentionally evaluated against the providers (not a cached snapshot)
    /// so a settings change is picked up on the very next keystroke. Runs independently of
    /// `shouldProcessEventsProvider` because the hotkey must work even when Cotabby is globally
    /// disabled — that is its only job.
    func handleToggleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            CotabbyLogger.app.warning("Toggle tap was disabled by system, re-enabling")
            if let toggleTap {
                CGEvent.tapEnable(tap: toggleTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if suppressionController.isSynthetic(event) {
                return Unmanaged.passUnretained(event)
            }

            let bound = globalToggleKeyCodeProvider()
            guard bound != Self.disabledKeyCode else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = keyCode(from: event)
            let modifiers = ShortcutModifierMask(eventFlags: event.flags)
            guard keyCode == bound, modifiers == globalToggleKeyModifiersProvider() else {
                return Unmanaged.passUnretained(event)
            }

            onGlobalToggleHotkey?()
            CotabbyLogger.app.debug("Toggle tap consumed keyCode=\(keyCode) modifiers=\(modifiers.rawValue)")
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Listen-only observer: classifies the event and notifies the coordinator. The return value
    /// of `onEvent` is ignored here because a listen-only tap cannot drop or modify events.
    /// Consumption of the accept key is handled by the separate active accept tap.
    ///
    /// Internal so tests can lock down which tap owns acceptance without installing real global
    /// event taps.
    func handleObserverTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            CotabbyLogger.app.warning("Observer tap was disabled by system, re-enabling")
            if let observerTap {
                CGEvent.tapEnable(tap: observerTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            // Identity first: every event the inserter posts carries the synthetic marker, which
            // survives any counter race. The countdown alone proved leaky under rapid accept
            // bursts (async tap delivery interleaves chunks), and one leaked synthetic keydown
            // classified as typing is enough to invalidate the very suggestion being accepted. This
            // also subsumes the #668 paste-path concern: the synthetic Cmd-V carries the marker, so
            // identity suppresses it even if a racing real keystroke consumed its countdown token
            // first. The countdown check below remains as the secondary gate for unmarked events.
            if suppressionController.isSynthetic(event) {
                _ = suppressionController.consumeIfNeeded()
                onSuppressedSyntheticInput?()
                return Unmanaged.passUnretained(event)
            }

            if suppressionController.consumeIfNeeded() {
                onSuppressedSyntheticInput?()
                return Unmanaged.passUnretained(event)
            }

            // Short-circuit before classification when Cotabby won't act on events for the
            // current app. Even though this tap is listen-only, classification still does work
            // on the main actor that we should skip when nothing will use the result.
            guard shouldProcessEventsProvider() else {
                return Unmanaged.passUnretained(event)
            }

            _ = routeObserverKeyDown(
                InputMonitorKeyEvent(
                    keyCode: keyCode(from: event),
                    characters: event.unicodeString,
                    flags: event.flags
                )
            )
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Testable observer path for semantic key snapshots.
    ///
    /// Production still enters through `handleObserverTap`; this method exists so tests can verify
    /// ownership rules without depending on CoreGraphics event allocation.
    func handleObserverKeyDown(_ keyEvent: InputMonitorKeyEvent) -> CapturedInputEvent? {
        guard shouldProcessEventsProvider() else {
            return nil
        }
        return routeObserverKeyDown(keyEvent)
    }

    /// Active accept tap: only consumes the configured accept keys, so the focused application
    /// never sees them when a suggestion is accepted. All other keys pass through unchanged.
    /// This tap owns acceptance because it can return `nil` for the exact key event that triggered
    /// insertion. The listen-only observer cannot do that safely.
    ///
    /// Internal so tests can verify that successful acceptance returns `nil` for the original key
    /// while declined acceptance passes that key through.
    func handleAcceptTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            CotabbyLogger.app.warning("Accept tap was disabled by system, re-enabling")
            if let acceptTap {
                CGEvent.tapEnable(tap: acceptTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            // The consuming tap has no suppression countdown of its own (the observer owns that), so
            // it recognizes Cotabby's synthetic insertion events by identity instead. Without this an
            // accept key bound to keyCode 0 (the inserter's placeholder virtualKey) would make the tap
            // swallow our own inserted text. Pass synthetic events straight through.
            if suppressionController.isSynthetic(event) {
                return Unmanaged.passUnretained(event)
            }

            guard shouldProcessEventsProvider() else {
                return Unmanaged.passUnretained(event)
            }

            let keyEvent = InputMonitorKeyEvent(keyCode: keyCode(from: event), flags: event.flags)
            switch resolveAcceptKeyDown(keyEvent) {
            case .consume:
                return nil
            case .notHandled, .passThrough:
                return Unmanaged.passUnretained(event)
            }

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Testable resolution of a keydown at the active tap: the emoji decider wins while a capture is
    /// open, otherwise the suggestion accept-key logic decides. `.notHandled` from the emoji decider
    /// means no capture is active, so the accept-key path takes over. Mirrors `handleAcceptTap`'s
    /// keydown branch without CoreGraphics event allocation.
    func resolveAcceptKeyDown(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        if let emojiCaptureKeyDecider {
            let decision = emojiCaptureKeyDecider(keyEvent)
            if decision != .notHandled {
                return decision
            }
        }
        return handleAcceptKeyDown(keyEvent)
    }

    /// Testable accept-tap path for semantic key snapshots.
    ///
    /// Returning a decision instead of a CoreGraphics callback result keeps the ownership rule easy
    /// to test: a successful coordinator accept is the only path that consumes the original key.
    func handleAcceptKeyDown(_ keyEvent: InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision {
        guard shouldProcessEventsProvider() else {
            return .passThrough
        }

        guard let kind = acceptanceKind(for: keyEvent) else {
            return .notHandled
        }

        // Fail open. A stale accept tap with no visible suggestion should never steal the user's
        // key. When a visible overlay exists, the coordinator remains the final validator and can
        // clean up stale UI before this method passes the original key through.
        guard shouldConsumeAcceptKeyProvider() else {
            let message = "Accept tap declining to consume keyCode=\(keyEvent.keyCode): "
                + "coordinator reports no visible suggestion"
            CotabbyLogger.app.debug("\(message)")
            return .passThrough
        }

        guard let onEvent else {
            CotabbyLogger.app.debug("Accept tap declining to consume keyCode=\(keyEvent.keyCode): no event handler")
            return .passThrough
        }

        let capturedEvent = CapturedInputEvent(
            kind: kind,
            keyCode: keyEvent.keyCode,
            characters: "",
            flags: keyEvent.flags
        )
        guard onEvent(capturedEvent) else {
            CotabbyLogger.app.debug(
                "Accept tap passed keyCode=\(keyEvent.keyCode) through because coordinator declined acceptance"
            )
            return .passThrough
        }

        let eventModifiers = ShortcutModifierMask(eventFlags: keyEvent.flags)
        CotabbyLogger.app.debug(
            "Accept tap consumed keyCode=\(keyEvent.keyCode) modifiers=\(eventModifiers.rawValue)"
        )
        return .consume
    }

    private func routeObserverKeyDown(_ keyEvent: InputMonitorKeyEvent) -> CapturedInputEvent? {
        // While an emoji capture is open, the accept key must reach the observer's `onEvent` so the
        // emoji controller can commit on it. The emoji commit fires from the listen-only observer pass
        // (the accept tap only swallows the key afterward), so suppressing the accept key here — which
        // we do whenever a ghost suggestion is concurrently visible (`isAcceptTapOwningAcceptKeys`) —
        // would freeze the emoji controller out of its own commit key and route Tab to the suggestion
        // accept path instead. Excluding capture from acceptance recognition keeps the emoji picker's
        // "first look at every keystroke" invariant intact even when a suggestion overlay is showing.
        let recognizesAcceptance = isAcceptTapOwningAcceptKeys && !captureInterceptionActive
        let capturedEvent = classify(keyEvent: keyEvent, recognizesAcceptance: recognizesAcceptance)
        guard !capturedEvent.kind.isAcceptance else {
            // Acceptance is handled by the active default tap, because only that callback can
            // make insertion and "consume the original key" one atomic decision. If the active
            // tap is absent, printable accept bindings are classified as ordinary typing.
            return nil
        }

        _ = onEvent?(capturedEvent)
        return capturedEvent
    }

    private func keyCode(from event: CGEvent) -> CGKeyCode {
        CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    }

    /// Reduces a key snapshot into the smaller event categories the suggestion coordinator understands.
    private func classify(keyEvent: InputMonitorKeyEvent, recognizesAcceptance: Bool = true) -> CapturedInputEvent {
        let keyCode = keyEvent.keyCode
        let flags = keyEvent.flags

        // Normalize to just the four bits we care about — `CGEventFlags` also carries caps lock,
        // numeric pad, secondary fn, and device flags that must not influence shortcut equality.
        if recognizesAcceptance, let kind = acceptanceKind(for: keyEvent) {
            return CapturedInputEvent(kind: kind, keyCode: keyCode, characters: "", flags: flags)
        }

        // We classify events by behavior instead of raw key codes alone.
        // That keeps the prediction layer coupled to "what happened" rather than "which key fired."
        if [123, 124, 125, 126].contains(keyCode) {
            return CapturedInputEvent(kind: .navigation, keyCode: keyCode, characters: "", flags: flags)
        }

        // Backspace (51) and forward-delete (117) mutate field content. Return (36) and Keypad
        // Enter (76) intentionally fall through to the dismissal block below alongside Escape.
        // Enter often acts as navigation rather than text input (Find Bar next-match, single-line
        // form submit, chat send), and even in multi-line fields the next character typed will
        // schedule a fresh prediction anyway — regenerating on Enter itself just masks the user's
        // post-Enter action with a stale overlay.
        if [51, 117].contains(keyCode) {
            return CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: "", flags: flags)
        }

        // 53 = Escape, 36 = Return, 76 = Keypad Enter.
        if [53, 36, 76].contains(keyCode) {
            return CapturedInputEvent(kind: .dismissal, keyCode: keyCode, characters: "", flags: flags)
        }

        if flags.contains(.maskCommand) {
            let mutationShortcutKeyCodes: Set<CGKeyCode> = [0, 6, 7, 9]
            let kind: CapturedInputEvent.Kind = mutationShortcutKeyCodes.contains(keyCode) ? .shortcutMutation : .dismissal
            return CapturedInputEvent(kind: kind, keyCode: keyCode, characters: "", flags: flags)
        }

        let characters = keyEvent.characters
        if !characters.trimmingCharacters(in: .controlCharacters).isEmpty {
            return CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: characters, flags: flags)
        }

        return CapturedInputEvent(kind: .other, keyCode: keyCode, characters: characters, flags: flags)
    }

    /// True when the key matches the user's configured word-accept binding (keyCode + modifiers),
    /// using the same match the suggestion accept path uses. The emoji picker commits on this key so
    /// its commit stays consistent with accepting a suggestion word instead of hardcoding Tab/Return.
    func isWordAcceptKey(_ keyEvent: InputMonitorKeyEvent) -> Bool {
        acceptanceKind(for: keyEvent) == .acceptance
    }

    private func acceptanceKind(for keyEvent: InputMonitorKeyEvent) -> CapturedInputEvent.Kind? {
        let eventModifiers = ShortcutModifierMask(eventFlags: keyEvent.flags)

        // Read shortcut state from the model at event time so changes are always current. Each binding
        // resolves once as a unit, so the key code and modifiers can never disagree and a per-app
        // override is scanned at most once per binding per keystroke.
        let fullAccept = fullAcceptanceBindingProvider()
        let accept = acceptanceBindingProvider()

        // Full-suggestion acceptance takes priority so pressing the full-accept key doesn't
        // silently fall through to word-accept when both are assigned. The bound modifier set must
        // match exactly after normalization, so `Tab` and `Shift+Tab` remain distinct bindings.
        if keyEvent.keyCode == fullAccept.keyCode, eventModifiers == fullAccept.modifiers {
            return .fullAcceptance
        }

        if keyEvent.keyCode == accept.keyCode, eventModifiers == accept.modifiers {
            return .acceptance
        }

        return nil
    }
}

extension InputMonitor: SuggestionInputMonitoring {}
extension InputMonitor: EmojiInputIntercepting {}

private extension CapturedInputEvent.Kind {
    /// Acceptance is the one event family that must be handled by the consuming tap, not the
    /// listen-only observer. The observer can describe these keys, but it cannot stop them.
    var isAcceptance: Bool {
        self == .acceptance || self == .fullAcceptance
    }
}

private extension CGEvent {
    var unicodeString: String {
        var length: Int = 0
        keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else {
            return ""
        }

        // Core Graphics fills a caller-provided UTF-16 buffer here, so we allocate manually and
        // then construct a Swift `String` from those code units. This is one of the common places
        // where Swift code still has to interact with C-style memory management explicitly.
        let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: length)
        defer {
            buffer.deallocate()
        }

        keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}
