import ApplicationServices

/// Maps macOS virtual key codes to human-readable labels for the settings UI.
/// Only covers keys that don't produce a useful `charactersIgnoringModifiers` string.
enum KeyCodeLabels {
    private static let specialKeys: [CGKeyCode: String] = [
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        117: "Forward Delete",
        36: "Return",
        76: "Enter",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    /// Best-effort labels for keys that exist on ISO/JIS layouts but produce no useful
    /// glyph via `charactersIgnoringModifiers` (dead keys, layout-specific physical keys).
    /// Used only when the fallback string is empty, so US-ANSI users never see these.
    private static let physicalKeyDescriptions: [CGKeyCode: String] = [
        10: "Key above Tab",
        50: "Key above Tab",
        93: "Key beside Right Shift"
    ]

    static func label(for keyCode: CGKeyCode, fallback: String?) -> String {
        if let special = specialKeys[keyCode] {
            return special
        }
        if let chars = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !chars.isEmpty {
            return chars.uppercased()
        }
        if let physical = physicalKeyDescriptions[keyCode] {
            return physical
        }
        return "Key \(keyCode)"
    }

    /// Builds the full shortcut label users see in the settings keycap and the ghost-text
    /// hint pill: `"⌥ Tab"`, `"⇧ ⌘ Space"`, or just `"Tab"` when no modifiers are bound.
    /// Glyph ordering matches macOS convention (Control, Option, Shift, Command).
    static func label(
        for keyCode: CGKeyCode,
        modifiers: ShortcutModifierMask,
        fallback: String?
    ) -> String {
        let keyLabel = label(for: keyCode, fallback: fallback)
        let glyphs = modifierGlyphs(modifiers)
        return glyphs.isEmpty ? keyLabel : "\(glyphs) \(keyLabel)"
    }

    static func modifierGlyphs(_ modifiers: ShortcutModifierMask) -> String {
        var result = ""
        if modifiers.contains(.control) { result.append("⌃") }
        if modifiers.contains(.option) { result.append("⌥") }
        if modifiers.contains(.shift) { result.append("⇧") }
        if modifiers.contains(.command) { result.append("⌘") }
        return result
    }
}
