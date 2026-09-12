import Foundation

/// Builds the focus snapshot the host is EXPECTED to publish after Cotabby inserts a final
/// accepted chunk: same field, preceding text extended by exactly what was typed, caret advanced
/// by its UTF-16 length.
///
/// Why this exists: after the final chunk of a suggestion is accepted, the next generation
/// otherwise waits for the host to publish the insert over Accessibility (10-400ms of polling)
/// before it can even start. Cotabby knows precisely what it just typed, so it can start the
/// next generation against this optimistic snapshot immediately and use the eventual publish as
/// validation: if the host's published content matches this snapshot's content signature, the
/// speculative result is exactly current; if anything differs (autocorrect, IME transformation,
/// a sliding context window), the signature mismatch drops the speculation and the normal
/// poll-driven regeneration takes over. Wrong speculation costs one discarded generation; right
/// speculation removes the publish wait plus a debounce from the visible gap.
nonisolated enum SpeculativeAcceptanceContext {
    static func optimisticSnapshot(
        after snapshot: FocusedInputSnapshot,
        inserting insertionChunk: String
    ) -> FocusedInputSnapshot {
        optimisticSnapshot(after: snapshot, precedingText: snapshot.precedingText + insertionChunk)
    }

    /// `snapshot` as it will read once the text before the caret is `precedingText`, a known
    /// insertion the host may not have published yet. The caret moves by the difference in length;
    /// everything after the caret stays.
    static func optimisticSnapshot(
        after snapshot: FocusedInputSnapshot,
        precedingText: String
    ) -> FocusedInputSnapshot {
        let lengthChange = precedingText.utf16.count - snapshot.precedingText.utf16.count
        return FocusedInputSnapshot(
            applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier,
            processIdentifier: snapshot.processIdentifier,
            elementIdentifier: snapshot.elementIdentifier,
            role: snapshot.role,
            subrole: snapshot.subrole,
            caretRect: snapshot.caretRect,
            inputFrameRect: snapshot.inputFrameRect,
            caretSource: snapshot.caretSource,
            caretQuality: snapshot.caretQuality,
            observedCharWidth: snapshot.observedCharWidth,
            observedContentEdges: snapshot.observedContentEdges,
            precedingText: precedingText,
            trailingText: snapshot.trailingText,
            selection: NSRange(
                location: max(0, snapshot.selection.location + lengthChange),
                length: 0
            ),
            isSecure: snapshot.isSecure,
            isIntegratedTerminal: snapshot.isIntegratedTerminal,
            focusChangeSequence: snapshot.focusChangeSequence,
            focusedURLString: snapshot.focusedURLString,
            resolvedFieldStyle: snapshot.resolvedFieldStyle,
            windowTitle: snapshot.windowTitle,
            fieldPlaceholder: snapshot.fieldPlaceholder,
            hostTextMetrics: snapshot.hostTextMetrics,
            elementFrameRect: snapshot.elementFrameRect,
            hostMarkedTextRange: snapshot.hostMarkedTextRange
        )
    }
}
