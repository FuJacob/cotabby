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

    /// The glyph to display and insert. Defaults to `entry.glyph`; the variant resolver overrides it
    /// with a skin-toned composition (e.g. 👋 -> 👋🏽) while keeping the source `entry` for ranking and
    /// the `:alias:` label.
    let displayGlyph: String

    init(entry: EmojiEntry, displayGlyph: String? = nil) {
        self.entry = entry
        self.displayGlyph = displayGlyph ?? entry.glyph
    }

    /// Identity is the displayed glyph so a neutral row and its skin-toned sibling (same `entry`)
    /// stay distinct in SwiftUI lists.
    var id: String { displayGlyph }
    var glyph: String { displayGlyph }

    /// Label shown next to the glyph. Falls back to the human description when an entry somehow has
    /// no aliases, so a row is never blank.
    var primaryAlias: String { entry.aliases.first ?? entry.name }
}

/// User-selectable skin tone applied to emoji that support Fitzpatrick modifiers.
enum EmojiSkinTone: String, CaseIterable, Equatable, Sendable {
    case neutral, light, mediumLight, medium, mediumDark, dark

    /// The Fitzpatrick modifier scalar inserted after a modifier-base scalar; `nil` for neutral.
    var modifier: String? {
        switch self {
        case .neutral: return nil
        case .light: return "\u{1F3FB}"
        case .mediumLight: return "\u{1F3FC}"
        case .medium: return "\u{1F3FD}"
        case .mediumDark: return "\u{1F3FE}"
        case .dark: return "\u{1F3FF}"
        }
    }

    var displayName: String {
        switch self {
        case .neutral: return "Default"
        case .light: return "Light"
        case .mediumLight: return "Medium Light"
        case .medium: return "Medium"
        case .mediumDark: return "Medium Dark"
        case .dark: return "Dark"
        }
    }

    /// A victory hand rendered in this tone, used by the settings swatch row. The neutral glyph
    /// needs the emoji variation selector so macOS does not fall back to the plain text symbol.
    var sampleGlyph: String {
        guard let modifier else {
            return "\u{270C}\u{FE0F}"
        }
        return "\u{270C}" + modifier
    }
}

/// User-selectable gender preference for emoji that ship neutral / man / woman variants.
enum EmojiGender: String, CaseIterable, Equatable, Sendable {
    case neutral, male, female

    var displayName: String {
        switch self {
        case .neutral: return "Person"
        case .male: return "Man"
        case .female: return "Woman"
        }
    }

    var sampleGlyph: String {
        switch self {
        case .neutral: return "\u{1F9D1}"   // 🧑
        case .male: return "\u{1F468}"      // 👨
        case .female: return "\u{1F469}"    // 👩
        }
    }
}

/// Snapshot of the emoji-customization settings the variant resolver reads at match time.
struct EmojiVariantPreferences: Equatable, Sendable {
    let skinTone: EmojiSkinTone
    let gender: EmojiGender

    static let `default` = EmojiVariantPreferences(skinTone: .neutral, gender: .neutral)
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
