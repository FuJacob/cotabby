import Foundation

/// File overview:
/// Focus rules shared by the inline-command captures: where a capture may open and when an open
/// capture still belongs to the field it started in. Accessibility focus is eventually consistent,
/// so both checks work from whatever snapshot is current and fail closed.
enum InlineCaptureFocusGate {
    /// The context a new capture may open against, or `nil` when the focused element is
    /// unsupported, secure, or not resolved yet (common right after a focus change).
    static func triggerableContext(in snapshot: FocusSnapshot) -> FocusedInputSnapshot? {
        guard case .supported = snapshot.capability,
              let context = snapshot.context,
              !context.isSecure else {
            return nil
        }
        return context
    }

    /// The context an open capture should keep following, or `nil` when the field changed or went
    /// secure underneath it. `focusChangeSequence` is the sequence recorded when the capture opened;
    /// a different value means the tracked `:query` / `/query` run is no longer under the caret.
    static func continuingContext(
        in snapshot: FocusSnapshot,
        focusChangeSequence: UInt64?
    ) -> FocusedInputSnapshot? {
        guard let context = snapshot.context,
              !context.isSecure,
              context.focusChangeSequence == focusChangeSequence else {
            return nil
        }
        return context
    }
}
