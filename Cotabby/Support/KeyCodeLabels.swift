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

    static func label(for keyCode: CGKeyCode, fallback: String?) -> String {
        if let special = specialKeys[keyCode] {
            return special
        }
        if let chars = fallback, !chars.isEmpty {
            return chars.uppercased()
        }
        return "Key \(keyCode)"
    }
}
