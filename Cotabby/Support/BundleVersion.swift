import Foundation

/// File overview:
/// Shared human-facing version text. The sidebar header and the Home hero both show the short
/// marketing version; formatting it in one place keeps the two surfaces from drifting apart.
/// (The About pane intentionally uses its own longer "Version X (build)" format.)
extension Bundle {
    /// Short marketing version prefixed for display (e.g. "v1.0"), or nil when the bundle carries
    /// no version string (some test hosts).
    var cotabbyDisplayVersion: String? {
        guard let shortVersion = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !shortVersion.isEmpty else {
            return nil
        }
        return "v\(shortVersion)"
    }
}
