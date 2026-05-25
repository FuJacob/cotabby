import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Owns the global keyboard event tap used to detect typing, navigation, dismissal keys,
/// and `Tab` acceptance. This is the boundary between raw CGEvents and Cotabby's smaller
/// input-event vocabulary.
///
/// `CapturedInputEvent` now lives in `Models/InputModels.swift` so the rest of the app can depend
/// on the semantic event type without importing this event-tap implementation.

/// Installs a session event tap.
/// We still observe normal typing, but we can now consume `Tab` when Cotabby has a valid suggestion.
@MainActor
final class InputMonitor {
    var onEvent: ((CapturedInputEvent) -> Bool)?
    var onSuppressedSyntheticInput: (() -> Void)?

    /// Reads the current word-accept key code from the model at event time, avoiding
    /// Combine delivery lag between settings changes and the event classifier.
    var acceptanceKeyCodeProvider: @MainActor () -> CGKeyCode = { 48 }

    /// Reads the current full-accept key code from the model at event time.
    var fullAcceptanceKeyCodeProvider: @MainActor () -> CGKeyCode = { CGKeyCode(UInt16.max) }

    /// When false, the tap passes keystrokes through without classifying or notifying the
    /// coordinator. This eliminates per-keystroke overhead in apps where Tabby will never act
    /// (terminals, globally disabled, per-app disabled).
    var shouldProcessEventsProvider: @MainActor () -> Bool = { true }

    private let permissionProvider: @MainActor () -> Bool
    private let suppressionController: InputSuppressionController

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(
        permissionProvider: @escaping @MainActor () -> Bool,
        suppressionController: InputSuppressionController
    ) {
        self.permissionProvider = permissionProvider
        self.suppressionController = suppressionController
    }

    /// Installs the event tap and begins listening for global keyboard activity.
    func start() {
        CotabbyLogger.app.info("Input monitor starting")
        refresh()
    }

    /// Removes the event tap and stops observing keyboard events.
    func stop() {
        CotabbyLogger.app.info("Input monitor stopping")
        destroyTap()
    }

    /// Re-evaluates whether the tap should exist after a permission change.
    func refresh() {
        if permissionProvider() {
            installTapIfNeeded()
        } else {
            destroyTap()
        }
    }

    /// Creates and enables the CGEvent tap only when permissions allow observation.
    private func installTapIfNeeded() {
        guard eventTap == nil else {
            return
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<InputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            // The CGEvent tap callback is a C function pointer. `assumeIsolated` tells Swift that
            // we are deliberately hopping back onto this `@MainActor` object before touching state.
            return MainActor.assumeIsolated {
                monitor.handleTap(type: type, event: event)
            }
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            CotabbyLogger.app.warning("Failed to create CGEvent tap — Input Monitoring permission may be missing")
            return
        }
        CotabbyLogger.app.info("CGEvent tap installed")

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Tears down the event tap and run-loop source to avoid leaking global event observers.
    private func destroyTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        runLoopSource = nil

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        eventTap = nil
    }

    /// Routes each raw keyboard event through suppression, classification, and optional interception.
    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            CotabbyLogger.app.warning("CGEvent tap was disabled by system, re-enabling")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            if suppressionController.consumeIfNeeded() {
                onSuppressedSyntheticInput?()
                return Unmanaged.passUnretained(event)
            }

            // Short-circuit before classification when Tabby won't act on events for the
            // current app (terminals, globally disabled, per-app disabled). The tap callback
            // runs synchronously before macOS delivers the keystroke, so any work here adds
            // latency the user feels in the target app.
            guard shouldProcessEventsProvider() else {
                return Unmanaged.passUnretained(event)
            }

            let capturedEvent = classify(event: event)
            let shouldIntercept = onEvent?(capturedEvent) ?? false
            return shouldIntercept ? nil : Unmanaged.passUnretained(event)

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

        // Read key codes from the model at event time so changes are always current.
        let fullAcceptKey = fullAcceptanceKeyCodeProvider()
        let acceptKey = acceptanceKeyCodeProvider()

        // Full-suggestion acceptance takes priority so pressing the full-accept key
        // doesn't silently fall through to word-accept when both are assigned.
        if keyCode == fullAcceptKey, noModifiers {
            return CapturedInputEvent(kind: .fullAcceptance, keyCode: keyCode, characters: characters, flags: flags)
        }

        if keyCode == acceptKey, noModifiers {
            return CapturedInputEvent(kind: .acceptance, keyCode: keyCode, characters: characters, flags: flags)
        }

        // We classify events by behavior instead of raw key codes alone.
        // That keeps the prediction layer coupled to "what happened" rather than "which key fired."
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
