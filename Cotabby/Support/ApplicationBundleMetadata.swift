import Foundation

/// File overview:
/// Resolves the durable identity of an application bundle the user picked from disk so Settings can
/// turn it into a disabled-app rule.
///
/// Why this exists: the "Add App" open panel hands back a file URL, but disable rules are keyed by
/// bundle identifier with a human-facing display name. Choosing that display name has a small
/// fallback order (Info.plist display name, then bundle name, then the file name on disk), and a
/// bundle without an identifier can never match a focused app, so it must be rejected. Keeping that
/// logic here — out of the SwiftUI view — makes the fallback order pure and unit-testable.
struct ApplicationBundleMetadata: Equatable {
    let bundleIdentifier: String
    let displayName: String
}

extension ApplicationBundleMetadata {
    /// Reads metadata from an on-disk application bundle. Returns `nil` when the URL is not a
    /// readable bundle or carries no bundle identifier, because a disable rule without a bundle
    /// identifier can never match the focused app the suggestion pipeline reports.
    init?(appURL: URL) {
        guard let bundle = Bundle(url: appURL) else {
            return nil
        }

        self.init(
            bundleIdentifier: bundle.bundleIdentifier,
            infoDisplayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            infoBundleName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            fileName: appURL.deletingPathExtension().lastPathComponent
        )
    }

    /// Pure resolution from already-extracted values, split out from `init(appURL:)` so the fallback
    /// order can be tested without a real bundle on disk.
    ///
    /// `CFBundleDisplayName` is the name shown in Finder and the Dock, so it wins; some apps ship
    /// only `CFBundleName`; a few ship neither, where the file name (minus `.app`) is the closest
    /// thing to what the user clicked. The bundle identifier is the last-resort label.
    init?(
        bundleIdentifier: String?,
        infoDisplayName: String?,
        infoBundleName: String?,
        fileName: String
    ) {
        guard let bundleIdentifier = Self.nonEmpty(bundleIdentifier) else {
            return nil
        }

        self.bundleIdentifier = bundleIdentifier
        displayName = Self.nonEmpty(infoDisplayName)
            ?? Self.nonEmpty(infoBundleName)
            ?? Self.nonEmpty(fileName)
            ?? bundleIdentifier
    }

    /// Trims surrounding whitespace and collapses an empty result to `nil` so the fallback chain can
    /// skip blank Info.plist values instead of surfacing them as the display name.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        return trimmed
    }
}
