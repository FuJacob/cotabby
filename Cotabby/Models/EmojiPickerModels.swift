import Foundation

/// File overview:
/// Shared value types for the inline `:emoji:` picker. These are intentionally small, `Equatable`,
/// and free of AppKit/Accessibility/CGEvent dependencies so the catalog, matcher, and trigger
/// state machine stay pure and easy to unit test. UI and runtime wiring live elsewhere.
///
/// The decoded dataset row mirrors the bundled `Resources/Emoji/emoji.json` schema exactly, so the
/// default `Decodable` synthesis can read it without custom `CodingKeys`.

/// One emoji record decoded from the bundled dataset.
///
/// `aliases` are the canonical `:name:` tokens a user types (for example `grinning`, `+1`), while
/// `keywords` are looser synonyms used only to widen search recall.
struct EmojiEntry: Equatable, Decodable {
    let glyph: String
    let name: String
    let aliases: [String]
    let keywords: [String]
    let group: String
    let unicodeVersion: String
}

/// A single ranked search result surfaced in the picker panel.
///
/// `id` is the glyph because the bundled dataset has one record per glyph, which keeps SwiftUI list
/// identity stable as the query narrows.
struct EmojiMatch: Equatable, Identifiable {
    let entry: EmojiEntry

    var id: String { entry.glyph }
    var glyph: String { entry.glyph }

    /// Label shown next to the glyph. Falls back to the human description when an entry somehow has
    /// no aliases, so a row is never blank.
    var primaryAlias: String { entry.aliases.first ?? entry.name }
}

// MARK: - Trigger state machine vocabulary

/// Direction for moving the highlighted row while the picker is open.
enum EmojiSelectionMove: Equatable {
    case up
    case down
}

/// How a capture was committed. `.key` is a consumed Tab/Return; `.closingColon` is the
/// passed-through second `:` of `:query:` (EMOJI.md Mode B).
enum EmojiCommitMode: Equatable {
    case key
    case closingColon
}

/// The reduced keystroke vocabulary the trigger state machine understands. The controller
/// translates raw `CapturedInputEvent`s plus focus signals into these.
enum EmojiTriggerInput: Equatable {
    case character(Character)
    case backspace
    case navigate(EmojiSelectionMove)
    case commitKey
    case escape
    case focusChanged
    case dismissExternally
}

/// Side effects the controller performs after a transition. The machine itself stays pure; it only
/// describes what should happen.
enum EmojiTriggerAction: Equatable {
    case open(query: String)
    case updateQuery(String)
    case moveSelection(EmojiSelectionMove)
    case commit(EmojiCommitMode)
    case cancel
}

/// The two lifecycle states. `idle` remembers the previously typed character so the trigger can
/// require a word boundary (start of field or after whitespace) before opening a capture.
enum EmojiTriggerState: Equatable {
    case idle(previousCharacter: Character?)
    case capturing(query: String)
}
