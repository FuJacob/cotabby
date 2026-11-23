import Foundation

/// File overview:
/// Pure rules for whether `AppUpdateManager` may start Sparkle and whether a launch checks for
/// updates at once. Kept apart from the manager so they are testable without Sparkle, the app's
/// Info.plist, or the network.
nonisolated enum AppUpdateStartPolicy {
    /// The product's update cadence, applied to Sparkle's scheduler and to the launch catch-up.
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    /// The stand-in an Info.plist carries before a real Sparkle public key is configured.
    static let publicKeyPlaceholder = "REPLACE_WITH_GENERATED_SPARKLE_PUBLIC_ED_KEY"

    /// Why the updater settings cannot start Sparkle, or nil when they can. Starting Sparkle with
    /// an unusable feed or key makes it show its "app is misconfigured" alert, so a build whose
    /// Info.plist still has the placeholder must not start it. Values arrive trimmed, blanks as nil.
    static func configurationProblem(feedURL: String?, publicKey: String?) -> String? {
        guard let feedURL, URL(string: feedURL) != nil else {
            return "Missing or invalid SUFeedURL."
        }
        guard let publicKey, publicKey != publicKeyPlaceholder else {
            return "SUPublicEDKey is missing or still using the placeholder value."
        }
        return nil
    }

    /// Whether a launch should check right away: when no check has happened yet, or the last one
    /// is at least a full interval old. Recent launches leave the check to Sparkle's scheduler, so
    /// reopening Cotabby cannot bypass the daily cadence.
    static func needsCatchUpCheck(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else {
            return true
        }
        return now.timeIntervalSince(lastCheck) >= automaticCheckInterval
    }
}
