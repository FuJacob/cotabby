import Carbon.HIToolbox
import Foundation
import Logging

/// File overview:
/// Tracks whether the active keyboard input source is a *composing* IME (Japanese kana, Chinese,
/// Korean, Vietnamese, ...). `SuggestionInserter` reads this to pick an IME-safe way to commit an
/// accepted suggestion: a synthetic Unicode keystroke gets re-absorbed into composition by an active
/// IME (the keycode-0 event re-enters the input method instead of landing as literal text), so when
/// this is true the inserter writes through Accessibility / paste instead. The classification rule is
/// the pure `CompositionInputModeClassifier`; this type owns the live read and the change subscription.
///
/// Out-of-process, Cotabby cannot inspect another app's `NSTextInputContext` or marked range, so the
/// only robust signal is which input source is selected. We read it via Text Input Sources (TIS) and
/// refresh on the distributed `kTISNotifySelectedKeyboardInputSourceChanged` notification, which fires
/// on every input-source AND mode switch (each IME mode is its own selectable source). Caching there
/// keeps `isComposingIMEActive` a synchronous, allocation-free read on the accept path.
@MainActor
final class KeyboardInputSourceMonitor {
    /// True while a composing input method is selected. Cached; refreshed on the input-source change
    /// notification, so reads at accept time are cheap and (since switching sources fires the
    /// notification first) current.
    private(set) var isComposingIMEActive = false

    private var observer: NSObjectProtocol?

    init() {
        refresh()
        // Mirror `PowerSourceMonitor`'s observer pattern: delivered on the main queue, so the
        // MainActor-isolated callback runs without an extra hop under the project's main-actor
        // default isolation.
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.selectedInputSourceChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleInputSourceChanged()
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// `kTISNotifySelectedKeyboardInputSourceChanged` bridged to a `Notification.Name`.
    private static let selectedInputSourceChangedNotification = Notification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String
    )

    private func handleInputSourceChanged() {
        let wasComposing = isComposingIMEActive
        refresh()
        if wasComposing != isComposingIMEActive {
            CotabbyLogger.app.info("Composing IME active changed to \(self.isComposingIMEActive)")
        }
    }

    /// Reads the current keyboard input source via TIS and recomputes `isComposingIMEActive`.
    private func refresh() {
        guard let unmanagedSource = TISCopyCurrentKeyboardInputSource() else {
            isComposingIMEActive = false
            return
        }
        let source = unmanagedSource.takeRetainedValue()

        let isKeyboardLayout = Self.stringProperty(source, kTISPropertyInputSourceType)
            == (kTISTypeKeyboardLayout as String)
        let inputModeID = Self.stringProperty(source, kTISPropertyInputModeID)

        isComposingIMEActive = CompositionInputModeClassifier.isComposingInputMode(
            isKeyboardLayout: isKeyboardLayout,
            inputModeID: inputModeID
        )
    }

    /// Reads a CFString-valued TIS property as a Swift `String`. `TISGetInputSourceProperty` returns a
    /// non-owning `void *` into the source, so the value is bridged with `takeUnretainedValue()`.
    private static func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
