import AppKit
import ApplicationServices
import Foundation
import Logging

/// File overview:
/// Commits accepted suggestions back into the host app by synthesizing Unicode keyboard events.
/// This keeps acceptance simple and app-agnostic, while pairing with suppression to avoid loops.
///
/// `insert(_:)` types a continuation. `replace(deletingUTF16Count:with:)` first deletes a run of
/// already-typed characters (the `:query` the user typed before the emoji picker) and then types the
/// replacement, which the emoji picker uses to swap `:smile` for its glyph.
@MainActor
final class SuggestionInserter {
    private let suppressionController: InputSuppressionController

    private(set) var lastErrorMessage: String?

    /// In-flight state for the opt-in paste path. The user's real clipboard is snapshotted once and
    /// restored after the paste lands. While a restore is pending, a second paste must NOT re-snapshot
    /// (the pasteboard then holds OUR completion, which would leak back to the user), so overlapping
    /// pastes coalesce onto this single saved clipboard and reschedule the one pending restore.
    private var pendingPasteboardRestore: DispatchWorkItem?
    private var savedClipboardForRestore: [[NSPasteboard.PasteboardType: Data]]?

    /// Virtual key code for Delete/Backspace. Posting these at the HID level deletes one UTF-16 unit
    /// of already-typed text per pair, which is how the picker removes the literal `:query` run.
    private static let backspaceKeyCode: CGKeyCode = 0x33

    /// Virtual key code for the `V` key, used to synthesize Cmd-V in the paste insertion path.
    private static let vKeyCode: CGKeyCode = 0x09

    /// UserDefaults key (no UI) that routes long or multi-line completions through a clipboard paste
    /// instead of a synthetic Unicode keystroke. Default-off: paste touches the user's clipboard and
    /// its restore timing needs on-device validation, so it stays a hidden dogfood toggle until then.
    private static let pasteInsertionDefaultsKey = "cotabbyPasteInsertionEnabled"
    private static var isPasteInsertionEnabled: Bool {
        UserDefaults.standard.bool(forKey: pasteInsertionDefaultsKey)
    }

    /// How long to leave the completion on the pasteboard before restoring the user's clipboard. Long
    /// enough for the host to service Cmd-V, short enough that the user's clipboard is theirs again
    /// almost immediately. Catalogued in `docs/POLLING_AND_DELAYS.md`; tune on device.
    private static let pasteboardRestoreDelay: TimeInterval = 0.15

    init(suppressionController: InputSuppressionController) {
        self.suppressionController = suppressionController
    }

    /// Posts a Unicode keydown/keyup pair for the accepted suggestion and reports any insertion failure.
    func insert(_ suggestion: String) -> Bool {
        let normalized = suggestion.replacingOccurrences(of: "\r", with: "")
        guard !normalized.isEmpty else {
            lastErrorMessage = "Suggestion was empty."
            CotabbyLogger.suggestion.warning("Insertion skipped: suggestion was empty after normalization")
            return false
        }

        // Paste path (opt-in): a long or multi-line completion is steadier as a clipboard paste in
        // apps that mishandle a big synthetic Unicode string. On any failure we fall through to the
        // reliable keystroke path below, so paste is never worse than the default keystroke insert.
        if InsertionStrategySelector.strategy(
            forChunk: normalized,
            pasteEnabled: Self.isPasteInsertionEnabled
        ) == .paste, insertViaPaste(normalized) {
            lastErrorMessage = nil
            CotabbyLogger.suggestion.debug("Inserted \(normalized.count) characters via clipboard paste")
            return true
        }

        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            lastErrorMessage = "Unable to create a synthetic keyboard event."
            CotabbyLogger.suggestion.error("Failed to create synthetic keyboard events for insertion")
            return false
        }

        let utf16CodeUnits = Array(normalized.utf16)
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        // Tag the synthetic events so both taps ignore them by identity. The observer also has a
        // countdown, but the consuming accept tap relies on this marker because these events arrive
        // with the placeholder `virtualKey: 0`, which would otherwise match an accept key bound to
        // keyCode 0.
        suppressionController.markSynthetic(keyDownEvent)
        suppressionController.markSynthetic(keyUpEvent)
        keyDownEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyUpEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        lastErrorMessage = nil
        CotabbyLogger.suggestion.debug("Inserted \(normalized.count) characters via synthetic keystroke")
        return true
    }

    /// Deletes `deletingUTF16Count` already-typed UTF-16 units, then types `text`. Used by the emoji
    /// picker to replace the literal `:query` (or `:query:`) run with the chosen glyph.
    ///
    /// All synthetic events are built first, then registered for suppression in a single call, then
    /// posted. Building before registering means a failed event allocation never leaves a phantom
    /// suppression token that would swallow the user's next real keystroke. Registering the whole
    /// burst once means every backspace and the insertion keydown fall inside one suppression window,
    /// so none of our own deletes are re-observed as user typing.
    func replace(deletingUTF16Count: Int, with text: String) -> Bool {
        let plan = SyntheticReplacePlanner.plan(deletingUTF16Count: deletingUTF16Count, text: text)
        guard !plan.isNoop else {
            lastErrorMessage = nil
            return true
        }

        var events: [CGEvent] = []
        events.reserveCapacity(plan.backspaceCount * 2 + 2)

        for _ in 0..<plan.backspaceCount {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: Self.backspaceKeyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: Self.backspaceKeyCode, keyDown: false) else {
                lastErrorMessage = "Unable to create a synthetic delete event."
                CotabbyLogger.suggestion.error("Replace failed: could not create delete events")
                return false
            }
            events.append(down)
            events.append(up)
        }

        if !plan.insertUTF16.isEmpty {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                lastErrorMessage = "Unable to create a synthetic keyboard event."
                CotabbyLogger.suggestion.error("Replace failed: could not create insertion events")
                return false
            }
            down.keyboardSetUnicodeString(stringLength: plan.insertUTF16.count, unicodeString: plan.insertUTF16)
            up.keyboardSetUnicodeString(stringLength: plan.insertUTF16.count, unicodeString: plan.insertUTF16)
            events.append(down)
            events.append(up)
        }

        // Tag every synthetic event so the consuming accept tap ignores them by identity, the same way
        // `insert(_:)` does. The insertion event uses the placeholder `virtualKey: 0`, which would
        // otherwise match an accept key bound to keyCode 0 and make the tap swallow our own glyph.
        for event in events {
            suppressionController.markSynthetic(event)
        }
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: plan.totalKeyDownCount)
        for event in events {
            event.post(tap: .cghidEventTap)
        }

        lastErrorMessage = nil
        CotabbyLogger.suggestion.debug(
            "Replaced \(plan.backspaceCount) unit(s) with \(plan.insertUTF16.count)-unit text via synthetic keystrokes"
        )
        return true
    }

    /// Commits `text` by placing it on the pasteboard and synthesizing Cmd-V, then restoring the
    /// user's clipboard shortly after. Returns false (having already restored the clipboard) if any
    /// synthetic event could not be created, so the caller falls back to keystroke insertion. The
    /// Cmd-V is tagged synthetic the same way `insert(_:)` tags its keydown so the consuming tap
    /// ignores it.
    private func insertViaPaste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        // Snapshot the user's clipboard only when no restore is already pending. If one is (an
        // overlapping paste), the pasteboard currently holds our previous completion, so re-snapshotting
        // would save that and leak it back to the user; reuse the already-saved real clipboard.
        if pendingPasteboardRestore == nil {
            savedClipboardForRestore = Self.snapshotPasteboard(pasteboard)
        }
        let saved = savedClipboardForRestore ?? []

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pendingPasteboardRestore?.cancel()
            Self.restorePasteboard(saved, to: pasteboard)
            clearPendingPasteboardRestore()
            return false
        }
        let expectedChangeCount = pasteboard.changeCount

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.vKeyCode, keyDown: false) else {
            pendingPasteboardRestore?.cancel()
            Self.restorePasteboard(saved, to: pasteboard)
            clearPendingPasteboardRestore()
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        suppressionController.markSynthetic(keyDown)
        suppressionController.markSynthetic(keyUp)
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Give the host time to service Cmd-V, then hand the clipboard back, but only if our completion
        // is still the thing on it. If the user copied something during the window, `changeCount`
        // advanced and we leave their new clipboard alone. An overlapping paste cancels this restore
        // and reschedules one for the same saved clipboard.
        pendingPasteboardRestore?.cancel()
        let restore = DispatchWorkItem { [weak self] in
            if NSPasteboard.general.changeCount == expectedChangeCount {
                Self.restorePasteboard(saved, to: NSPasteboard.general)
            }
            self?.clearPendingPasteboardRestore()
        }
        pendingPasteboardRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteboardRestoreDelay, execute: restore)
        return true
    }

    /// Clears the in-flight paste-restore bookkeeping once a restore has run (or been abandoned on a
    /// failure path), so the next paste snapshots the user's real clipboard afresh.
    private func clearPendingPasteboardRestore() {
        pendingPasteboardRestore = nil
        savedClipboardForRestore = nil
    }

    /// Captures every representation of every pasteboard item so the user's clipboard can be restored
    /// exactly, not just its plain-text form.
    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types where item.data(forType: type) != nil {
                representations[type] = item.data(forType: type)
            }
            return representations
        }
    }

    private static func restorePasteboard(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

/// The synthetic key plan for a replace operation, kept pure so the accounting (how many backspaces,
/// how many suppression tokens) is unit testable without allocating CoreGraphics events. App-hosted
/// macOS tests can crash in CGEvent allocation/teardown, so the value-level math lives here.
struct SyntheticReplacePlan: Equatable {
    let backspaceCount: Int
    let insertUTF16: [UInt16]

    /// Number of keydown events the observer tap will see, and therefore the number of suppression
    /// tokens to arm. The Unicode insertion is a single keydown regardless of how many UTF-16 units
    /// it carries; keyups are a different event type and are not counted.
    var totalKeyDownCount: Int {
        backspaceCount + (insertUTF16.isEmpty ? 0 : 1)
    }

    var isNoop: Bool {
        backspaceCount == 0 && insertUTF16.isEmpty
    }
}

enum SyntheticReplacePlanner {
    static func plan(deletingUTF16Count: Int, text: String) -> SyntheticReplacePlan {
        let normalized = text.replacingOccurrences(of: "\r", with: "")
        return SyntheticReplacePlan(
            backspaceCount: max(deletingUTF16Count, 0),
            insertUTF16: Array(normalized.utf16)
        )
    }
}

extension SuggestionInserter: SuggestionInserting {}
extension SuggestionInserter: EmojiTextInserting {}
