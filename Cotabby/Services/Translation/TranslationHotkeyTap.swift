import CoreGraphics
import Foundation
import Logging

/// The "replace my draft with its translation" shortcut.
///
/// A consuming event tap, so the key never reaches the chat app (⌥T would otherwise type "†"). It
/// is installed only while a reply translation is on offer and removed as soon as it is not, so
/// Cotabby sits in the keystroke path for this feature only while the card is visible. Synthetic
/// events Cotabby posts itself are ignored, matching the other taps (`InputMonitor`).
@MainActor
final class TranslationHotkeyTap {
    private let suppressionController: InputSuppressionController
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyCode: CGKeyCode = 0
    private var modifiers: UInt32 = 0
    private var onPress: (() -> Void)?

    init(suppressionController: InputSuppressionController) {
        self.suppressionController = suppressionController
    }

    var isInstalled: Bool { tap != nil }

    func install(keyCode: CGKeyCode, modifiers: UInt32, onPress: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.onPress = onPress
        guard tap == nil else { return }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<TranslationHotkeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return MainActor.assumeIsolated { owner.handle(type: type, event: event) }
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            CotabbyLogger.app.warning("Failed to create the translation shortcut tap")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        runLoopSource = source
    }

    func remove() {
        onPress = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            guard !suppressionController.isSynthetic(event),
                  CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode,
                  ShortcutModifierMask(eventFlags: event.flags).rawValue == modifiers,
                  let onPress
            else { return Unmanaged.passUnretained(event) }
            onPress()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
