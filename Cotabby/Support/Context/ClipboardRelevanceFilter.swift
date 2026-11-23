import Foundation

/// Decides whether the current clipboard content is relevant enough to inject into the
/// autocomplete prompt. Tracks clipboard identity via an external change count, records when
/// the clipboard last changed during this Cotabby session, and applies two heuristics:
/// staleness and token overlap.
///
/// Why no source-app affinity: we never observe the actual copier — only the app that is
/// frontmost when autocomplete fires, which is always the typing app. Recording the typing
/// app as the "source" granted same-app shortcuts in apps where the user merely typed,
/// bypassing the overlap guard for unrelated clipboard content.
///
/// Why a baseline: `NSPasteboard.changeCount` is a non-zero cumulative counter, so treating the
/// first observation as a copy would reset the staleness clock to "now" and grant up to five
/// minutes of injection for content copied hours before Cotabby launched. The first observation
/// only records the baseline, so injection waits for an actual change.
///
/// The filter never reads `NSPasteboard` directly — the caller passes in a plain `Int` change
/// count and the raw clipboard string, keeping this type fully testable without AppKit.
@MainActor
final class ClipboardRelevanceFilter: ClipboardRelevanceFiltering {
    static let staleThresholdSeconds: TimeInterval = 300
    private static let minimumTokenLength = 3

    /// What the filter knows about the clipboard's history this session.
    private enum Observation {
        /// No change count seen yet.
        case none
        /// The clipboard as first seen. It has not changed since, so how old it is is unknown.
        case baseline(changeCount: Int)
        /// The clipboard changed while Cotabby was running, which dates the current content.
        case changed(changeCount: Int, at: Date)
    }

    private var observation = Observation.none
    private let dateProvider: () -> Date

    init(dateProvider: @escaping () -> Date = { Date() }) {
        self.dateProvider = dateProvider
    }

    /// Returns `clipboard` unchanged when it looks relevant, or `nil` when it should be dropped.
    func filter(
        clipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String
    ) -> String? {
        guard let clipboard else { return nil }

        switch observation {
        case .none:
            // Pre-existing clipboard content is not injected until the user actually copies again
            // while Cotabby is running.
            observation = .baseline(changeCount: pasteboardChangeCount)
            return nil
        case .baseline(let changeCount), .changed(let changeCount, _):
            if pasteboardChangeCount != changeCount {
                observation = .changed(changeCount: pasteboardChangeCount, at: dateProvider())
            }
        }

        guard case .changed(_, let lastChangeDate) = observation,
              dateProvider().timeIntervalSince(lastChangeDate) < Self.staleThresholdSeconds
        else {
            return nil
        }

        let clipboardTokens = Self.tokens(from: clipboard)
        let prefixTokens = Self.tokens(from: precedingText)
        guard !clipboardTokens.isDisjoint(with: prefixTokens) else {
            return nil
        }

        return clipboard
    }

    private static func tokens(from text: String) -> Set<String> {
        PromptContextSanitizer.significantTokens(from: text, minimumLength: minimumTokenLength)
    }
}
