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
        let insertedUTF16Count = insertionChunk.utf16.count
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
            precedingText: snapshot.precedingText + insertionChunk,
            trailingText: snapshot.trailingText,
            selection: NSRange(
                location: snapshot.selection.location + insertedUTF16Count,
                length: 0
            ),
            isSecure: snapshot.isSecure,
            isIntegratedTerminal: snapshot.isIntegratedTerminal,
            focusChangeSequence: snapshot.focusChangeSequence,
            focusedURLString: snapshot.focusedURLString,
            resolvedFieldStyle: snapshot.resolvedFieldStyle,
            windowTitle: snapshot.windowTitle,
            fieldPlaceholder: snapshot.fieldPlaceholder
        )
    }
}
