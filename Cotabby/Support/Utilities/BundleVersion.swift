import Foundation

/// File overview:
/// Shared human-facing version text. The sidebar header and the Home hero both show the short
/// marketing version; formatting it in one place keeps the two surfaces from drifting apart.
/// (The About pane intentionally uses its own longer "Version X (build)" format.) The raw
/// Info.plist reads live here too so no call site spells the dictionary keys by hand.
extension Bundle {
    /// `CFBundleShortVersionString` exactly as shipped (e.g. "0.4.2-beta"), or nil when absent.
    var cotabbyShortVersion: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// `CFBundleVersion` exactly as shipped, or nil when absent.
    var cotabbyBuildNumber: String? {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// Short marketing version prefixed for display (e.g. "v1.0"), or nil when the bundle carries
    /// no version string (some test hosts).
    var cotabbyDisplayVersion: String? {
        guard let shortVersion = cotabbyShortVersion, !shortVersion.isEmpty else {
            return nil
        }
        return "v\(shortVersion)"
    }
}
