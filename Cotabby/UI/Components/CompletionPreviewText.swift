import Foundation

/// A translated sentence split at the point where a completion preview changes from typed text to
/// ghost text.
///
/// The demo views own their animations and colors; this value only preserves the sentence as one
/// localization unit, then exposes the two display runs those views need. Keeping the split here
/// avoids translating half-sentences independently, which can produce broken word order in other
/// languages. The literal `¦` is a translator-movable marker and must appear exactly once.
struct CompletionPreviewText: Equatable, Sendable {
    let typedText: String
    let ghostText: String

    init(resolvedSentence: String) {
        let parts = resolvedSentence.components(separatedBy: "¦")
        // Catalogs can be edited outside the checked importer. A malformed marker should degrade
        // the decorative preview to a readable sentence, never terminate the menu-bar app.
        if parts.count == 2 {
            typedText = parts[0]
            ghostText = parts[1]
        } else {
            typedText = resolvedSentence.replacingOccurrences(of: "¦", with: "")
            ghostText = ""
        }
    }
}
