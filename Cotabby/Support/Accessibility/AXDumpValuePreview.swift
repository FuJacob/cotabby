import Foundation

/// File overview:
/// What the developer AX tree dump (`AXTreeDumpWriter`) prints for one element's value.
///
/// The dump walks the focused element's ancestors and children and prints the value it finds on
/// each. On a sign-in page that walk reaches the password field, and the dump used to copy the
/// typed password into a plain-text file before any secure-field check ran. The redaction rule
/// lives here, pure, so it is tested without a live Accessibility tree; the writer decides which
/// elements are secure with `SecureFieldDetector`, the same policy that keeps suggestions out of them.
nonisolated enum AXDumpValuePreview {
    /// Longer values are cut to this many characters; the dump is for geometry and structure, and
    /// the length is printed separately.
    static let previewLimit = 80

    /// Printed instead of a secure element's value. It carries no length either, because a
    /// password's length is itself worth keeping out of a file.
    static let redactedValue = "<redacted: secure field>"

    /// The text after `value:` on a node's line. `isSecure` is true for a secure element and for
    /// every element inside one, since a host can expose the typed text on a child as well.
    static func line(for text: String, isSecure: Bool) -> String {
        guard !isSecure else { return redactedValue }
        let preview = text.count > previewLimit ? String(text.prefix(previewLimit)) + "…" : text
        return "\"\(preview.replacingOccurrences(of: "\n", with: "\\n"))\" (len=\(text.count))"
    }
}
