import Foundation

/// Narrow persistence surface for `EmojiUsageStore`, so it can be unit-tested against an in-memory
/// store instead of process-global `UserDefaults` (which is shared across tests and unreliable to
/// mutate from a sandboxed unit-test host). `UserDefaults` already satisfies every requirement, so
/// production wiring is unchanged.
protocol EmojiUsageDefaults: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: EmojiUsageDefaults {}

/// File overview:
/// Persists per-user emoji usage (recents + frequency) so the picker ranks a person's go-to emoji
/// first and seeds the bare-`:` panel with them. Keyed by primary alias, which is variant-stable
/// (see `EmojiUsageSnapshot`), so using 👍🏽 still strengthens the 👍 concept.
///
/// `@MainActor` because the only writer is the main-actor `EmojiPickerController` at commit time, and
/// reads are cheap snapshots taken between keystrokes. State is stored as a single JSON blob so the
/// read/write is atomic and avoids per-key dictionary bridging quirks.
///
/// The `deinit` is `nonisolated` to dodge a macOS 14 Swift bug: an isolated deinit on a `@MainActor`
/// class with non-trivial stored properties routes through `swift_task_deinitOnExecutorMainActorBackDeploy`,
/// which over-releases and aborts the process ("pointer being freed was not allocated") when an
/// instance is destroyed — it crashed the app-hosted unit tests deterministically. Releasing the
/// stored UserDefaults reference plus value types is thread-safe and needs no main-actor hop.
@MainActor
final class EmojiUsageStore {
    private let defaults: EmojiUsageDefaults
    private var recents: [String]
    private var frequency: [String: Int]

    /// Cap on stored recents: ample for the panel (which shows ~24) while keeping the persisted blob
    /// small. Older aliases fall off the end as new emoji are committed.
    private static let recentsCap = 50
    /// Bounds for the frequency map, which previously grew one entry per unique emoji forever.
    /// Frequency only breaks ties inside a relevance tier, so trimming the rarest entries cannot
    /// change which emoji match a query. Trimming triggers above `frequencyCap` and cuts down to
    /// `frequencyTrimTarget` so steady use does not re-sort the map on every commit.
    private static let frequencyCap = 300
    private static let frequencyTrimTarget = 200
    private static let storageKey = "cotabbyEmojiUsage"

    private struct Persisted: Codable {
        var recents: [String]
        var frequency: [String: Int]
    }

    init(defaults: EmojiUsageDefaults = UserDefaults.standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            recents = decoded.recents
            frequency = decoded.frequency
        } else {
            recents = []
            frequency = [:]
        }
    }

    // See the type doc comment: avoids the macOS 14 isolated-deinit back-deploy crash.
    nonisolated deinit {}

    /// Records one commit of `alias` (an emoji's primary alias): moves it to the front of recents and
    /// increments its frequency, then persists. No-op for blank input.
    func record(alias rawAlias: String) {
        let alias = rawAlias.lowercased().trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty else { return }
        recents.removeAll { $0 == alias }
        recents.insert(alias, at: 0)
        if recents.count > Self.recentsCap {
            recents.removeLast(recents.count - Self.recentsCap)
        }
        frequency[alias, default: 0] += 1
        trimFrequencyIfNeeded()
        persist()
    }

    /// Drops the least-used aliases once the map outgrows its cap, keeping current recents so a
    /// just-used emoji can never lose its favorite ranking to the trim.
    private func trimFrequencyIfNeeded() {
        guard frequency.count > Self.frequencyCap else {
            return
        }

        let keepAlways = Set(recents)
        let removable = frequency
            .filter { !keepAlways.contains($0.key) }
            .sorted { $0.value < $1.value }
        // The effective floor is the larger of the trim target and the protected recents, so the
        // bound holds by construction even if `recentsCap` is ever raised past
        // `frequencyTrimTarget` instead of silently under-trimming.
        let effectiveTarget = max(Self.frequencyTrimTarget, keepAlways.count)
        let overflow = frequency.count - effectiveTarget
        for (alias, _) in removable.prefix(overflow) {
            frequency.removeValue(forKey: alias)
        }
    }

    /// Immutable snapshot for the pure ranker and recents helper.
    func snapshot() -> EmojiUsageSnapshot {
        EmojiUsageSnapshot(recentAliases: recents, frequency: frequency)
    }

    /// Forgets all recents and frequency. Backs the "Clear Emoji History" settings control.
    func clear() {
        recents = []
        frequency = [:]
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Persisted(recents: recents, frequency: frequency)) else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }
}
