import Foundation

/// Decides whether the current clipboard content is relevant enough to inject into the
/// autocomplete prompt. Tracks clipboard identity via an external change count, records when
/// the clipboard last changed and which app was frontmost at that moment, then applies three
/// heuristics: staleness, app affinity, and token overlap.
///
/// The filter never reads `NSPasteboard` directly — the caller passes in a plain `Int` change
/// count and the raw clipboard string, keeping this type fully testable without AppKit.
@MainActor
final class ClipboardRelevanceFilter {
    static let staleThresholdSeconds: TimeInterval = 300
    private static let minimumTokenLength = 3

    private var lastKnownChangeCount: Int = 0
    private var lastChangeDate: Date?
    private var sourceBundleIdentifier: String?
    private let dateProvider: () -> Date

    init(dateProvider: @escaping () -> Date = { Date() }) {
        self.dateProvider = dateProvider
    }

    /// Returns `clipboard` unchanged when it looks relevant, or `nil` when it should be dropped.
    func filter(
        clipboard: String?,
        pasteboardChangeCount: Int,
        currentBundleIdentifier: String,
        precedingText: String
    ) -> String? {
        guard let clipboard else { return nil }

        if pasteboardChangeCount != lastKnownChangeCount {
            lastKnownChangeCount = pasteboardChangeCount
            lastChangeDate = dateProvider()
            sourceBundleIdentifier = currentBundleIdentifier
        }

        guard let lastChangeDate,
              dateProvider().timeIntervalSince(lastChangeDate) < Self.staleThresholdSeconds
        else {
            return nil
        }

        if sourceBundleIdentifier == currentBundleIdentifier {
            return clipboard
        }

        let clipboardTokens = Self.tokens(from: clipboard)
        let prefixTokens = Self.tokens(from: precedingText)
        guard !clipboardTokens.isDisjoint(with: prefixTokens) else {
            return nil
        }

        return clipboard
    }

    // MARK: - Tokenization

    private static func tokens(from text: String) -> Set<String> {
        let words = text.lowercased().components(separatedBy: .alphanumerics.inverted)
        return Set(words.filter { $0.count >= minimumTokenLength })
    }
}
