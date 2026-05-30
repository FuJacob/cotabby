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

    /// Reads the current word-accept key code from the model at event time, avoiding
    /// Combine delivery lag between settings changes and the event classifier.
    var acceptanceKeyCodeProvider: @MainActor () -> CGKeyCode = { 48 }

    /// Modifier mask required alongside the word-accept key code. Empty means the bare key.
    var acceptanceKeyModifiersProvider: @MainActor () -> ShortcutModifierMask = { [] }

    /// Reads the current full-accept key code from the model at event time.
    var fullAcceptanceKeyCodeProvider: @MainActor () -> CGKeyCode = { CGKeyCode(UInt16.max) }

    /// Modifier mask required alongside the full-accept key code. Empty means the bare key.
    var fullAcceptanceKeyModifiersProvider: @MainActor () -> ShortcutModifierMask = { [] }

    /// When false, the observer passes keystrokes through without classifying or notifying the
    /// coordinator. This eliminates per-keystroke overhead in apps where Cotabby will never act
    /// (terminals, globally disabled, per-app disabled).
    var shouldProcessEventsProvider: @MainActor () -> Bool = { true }

    /// Fail-open authorization for routing a matching accept key into the active accept tap.
    /// The tap still consumes only when the coordinator successfully accepts the event; this
    /// preflight keeps stale or misinstalled taps from even attempting acceptance.
    var shouldConsumeAcceptKeyProvider: @MainActor () -> Bool = { false }

    private let permissionProvider: @MainActor () -> Bool
    private let suppressionController: InputSuppressionController

    private var observerTap: CFMachPort?
    private var observerRunLoopSource: CFRunLoopSource?

    private var acceptTap: CFMachPort?
    private var acceptRunLoopSource: CFRunLoopSource?

    /// Tracks whether the consuming tap currently owns accept-key semantics. This is separate
    /// from "a suggestion exists": the observer should only suppress accept-key callbacks when a
    /// real default tap can make the consume/pass-through decision for that same physical key.
    ///
    /// Internal instead of private so unit tests can exercise observer routing without installing
    /// global event taps.
    var isAcceptTapOwningAcceptKeys = false

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
    /// the next time the coordinator presents a suggestion.
    func refresh() {
        if permissionProvider() {
            installObserverTapIfNeeded()
        } else {
            destroyAcceptTap()
            destroyObserverTap()
        }
    }

    /// Installs (when `active == true`) or removes (when `false`) the narrow active tap that can
    /// consume the accept key. The coordinator calls this when a suggestion becomes visible or
    /// hidden, so Cotabby only enters the synchronous event path while there is something to accept.
    func setAcceptInterceptionActive(_ active: Bool) {
        guard permissionProvider() else {
            destroyAcceptTap()
            return
        }
        if active {
            installAcceptTapIfNeeded()
        } else {
            destroyAcceptTap()
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
        guard acceptTap == nil else {
            isAcceptTapOwningAcceptKeys = true
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
        isAcceptTapOwningAcceptKeys = true
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

            let capturedEvent = classify(event: event, recognizesAcceptance: isAcceptTapOwningAcceptKeys)
            guard !capturedEvent.kind.isAcceptance else {
                // Acceptance is handled by the active default tap, because only that callback can
                // make insertion and "consume the original key" one atomic decision. If the active
                // tap is absent, printable accept bindings are classified as ordinary typing.
                return Unmanaged.passUnretained(event)
            }

            _ = onEvent?(capturedEvent)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
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
            guard shouldProcessEventsProvider() else {
                return Unmanaged.passUnretained(event)
            }

            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            // Normalize to just the four bits we honor — caps lock, fn, numeric pad, and device
            // flags must not influence shortcut equality.
            let eventModifiers = ShortcutModifierMask(eventFlags: event.flags)

            let fullAcceptMatches = keyCode == fullAcceptanceKeyCodeProvider()
                && eventModifiers == fullAcceptanceKeyModifiersProvider()
            let acceptMatches = keyCode == acceptanceKeyCodeProvider()
                && eventModifiers == acceptanceKeyModifiersProvider()

            if fullAcceptMatches || acceptMatches {
                // Fail-open preflight. A stale accept tap should never ask the coordinator to
                // insert text. The coordinator still performs full AX/session validation below
                // before this callback consumes the original key.
                guard shouldConsumeAcceptKeyProvider() else {
                    let message = "Accept tap declining to consume keyCode=\(keyCode): "
                        + "coordinator reports no visible active session"
                    CotabbyLogger.app.debug("\(message)")
                    return Unmanaged.passUnretained(event)
                }

                guard let onEvent else {
                    CotabbyLogger.app.debug("Accept tap declining to consume keyCode=\(keyCode): no event handler")
                    return Unmanaged.passUnretained(event)
                }

                let kind: CapturedInputEvent.Kind = fullAcceptMatches ? .fullAcceptance : .acceptance
                let capturedEvent = CapturedInputEvent(
                    kind: kind,
                    keyCode: keyCode,
                    characters: "",
                    flags: event.flags
                )
                guard onEvent(capturedEvent) else {
                    CotabbyLogger.app.debug(
                        "Accept tap passed keyCode=\(keyCode) through because coordinator declined acceptance"
                    )
                    return Unmanaged.passUnretained(event)
                }

                CotabbyLogger.app.debug(
                    "Accept tap consumed keyCode=\(keyCode) modifiers=\(eventModifiers.rawValue)"
                )
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Reduces a raw CGEvent into the smaller event categories the suggestion coordinator understands.
    private func classify(event: CGEvent, recognizesAcceptance: Bool = true) -> CapturedInputEvent {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Normalize to just the four bits we care about — `CGEventFlags` also carries caps lock,
        // numeric pad, secondary fn, and device flags that must not influence shortcut equality.
        let eventModifiers = ShortcutModifierMask(eventFlags: flags)

        if recognizesAcceptance {
            // Read shortcut state from the model at event time so changes are always current.
            let fullAcceptKey = fullAcceptanceKeyCodeProvider()
            let fullAcceptModifiers = fullAcceptanceKeyModifiersProvider()
            let acceptKey = acceptanceKeyCodeProvider()
            let acceptModifiers = acceptanceKeyModifiersProvider()

            // Full-suggestion acceptance takes priority so pressing the full-accept key
            // doesn't silently fall through to word-accept when both are assigned.
            // The acceptance checks run before the Command-key branch below so a binding like
            // `⌘Tab` is classified as acceptance instead of being eaten by the shortcutMutation
            // path. The bound modifier set must match the masked event modifiers exactly, so
            // `Tab` and `⇧Tab` are distinct bindings and neither one triggers the other.
            if keyCode == fullAcceptKey, eventModifiers == fullAcceptModifiers {
                return CapturedInputEvent(kind: .fullAcceptance, keyCode: keyCode, characters: "", flags: flags)
            }

            if keyCode == acceptKey, eventModifiers == acceptModifiers {
                return CapturedInputEvent(kind: .acceptance, keyCode: keyCode, characters: "", flags: flags)
            }
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

        let characters = event.unicodeString
        if !characters.trimmingCharacters(in: .controlCharacters).isEmpty {
            return CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: characters, flags: flags)
        }

        return CapturedInputEvent(kind: .other, keyCode: keyCode, characters: characters, flags: flags)
    }
}

extension InputMonitor: SuggestionInputMonitoring {}

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
