import Foundation

/// File overview:
/// Where a user stands with first-run onboarding, and the rules for moving between those states.
/// Two persisted integers carry it: the onboarding version the user last finished, and the
/// furthest step reached in an unfinished run. Every question the app asks about onboarding
/// (show the wizard? where does it open? is this a returning user?) is answered here from those
/// two numbers, so the rules live in one testable place instead of at each call site.
struct OnboardingProgress: Equatable {
    /// Bump whenever onboarding is revamped enough that users who already finished an older version
    /// should experience it again. Anyone whose stored completed version is below this is shown the
    /// wizard, and finishing it writes this value back.
    static let currentVersion = 2

    /// The three situations a launch can find the user in.
    enum Status: Equatable {
        /// Has never reached "done" in any onboarding version.
        case neverCompleted
        /// Finished an older onboarding and is being shown the revamped flow. This user already has
        /// tuned settings, which the wizard must not overwrite with template defaults.
        case completedEarlierVersion
        /// Finished the current onboarding; the wizard stays out of the way.
        case completedCurrentVersion
    }

    /// The onboarding version the user last *completed* (reached "done" and dismissed), not a
    /// yes/no flag. `0` means never, which is also what an absent key reads as.
    let completedVersion: Int

    /// Raw `WelcomeStep` index of the furthest step reached in an unfinished run; `0` when there is
    /// none. Kept as the stored integer rather than a `WelcomeStep` so an index this build cannot
    /// interpret survives a round trip untouched instead of being silently rewritten.
    let furthestStepIndex: Int

    var status: Status {
        if completedVersion >= Self.currentVersion {
            return .completedCurrentVersion
        }
        return completedVersion > 0 ? .completedEarlierVersion : .neverCompleted
    }

    /// Whether the wizard should stay hidden at launch.
    var isCompleted: Bool {
        status == .completedCurrentVersion
    }

    /// Whether the user finished some onboarding version before, current or not.
    var isReturningUser: Bool {
        status != .neverCompleted
    }

    /// The step the wizard opens on. An index that does not name a step (absent, corrupt, or from a
    /// different numbering scheme) falls back to the beginning, which is always a safe place to be.
    var resumeStep: WelcomeStep {
        WelcomeStep(rawValue: furthestStepIndex) ?? .welcome
    }

    /// Progress after the wizard shows `step`. Monotonic: stepping back never lowers the resume
    /// point, so reopening the wizard always lands on the deepest step the user saw. That matters
    /// because granting Accessibility or Input Monitoring usually needs a relaunch, which would
    /// otherwise restart onboarding from the top every time (issue #314).
    func reaching(_ step: WelcomeStep) -> OnboardingProgress {
        guard step.rawValue > furthestStepIndex else {
            return self
        }
        return OnboardingProgress(completedVersion: completedVersion, furthestStepIndex: step.rawValue)
    }

    /// Progress after the user finishes the wizard. Stamps the current version and drops the resume
    /// point, so reopening the wizard later (from the menu, or after a future version bump) starts
    /// at the welcome step rather than the last step of this run.
    func completing() -> OnboardingProgress {
        OnboardingProgress(completedVersion: Self.currentVersion, furthestStepIndex: 0)
    }
}

// MARK: - Persistence

extension OnboardingProgress {
    /// Replaces the legacy boolean `cotabbyOnboardingCompleted` key (and the even older
    /// `hasShownWelcomeWindow`). Neither is migrated on purpose: reading them as "completed" would
    /// let upgrading users skip the revamped flow, which is the opposite of what a version bump is
    /// for, and the older one was set before the user had finished anything.
    static let completedVersionKey = "cotabbyOnboardingCompletedVersion"

    /// The "2" suffix marks the second step-numbering scheme (a redesign folded the writing-style
    /// step into "personalize", shifting every later raw index). Reading the old key would resume a
    /// mid-flow user onto the wrong step, so it is abandoned rather than reinterpreted. Any future
    /// change to `WelcomeStep`'s numbering must bump this suffix again.
    static let furthestStepKey = "cotabbyOnboardingProgressStep2"

    static func load(from userDefaults: UserDefaults) -> OnboardingProgress {
        OnboardingProgress(
            completedVersion: userDefaults.integer(forKey: completedVersionKey),
            furthestStepIndex: userDefaults.integer(forKey: furthestStepKey)
        )
    }

    /// Writes this progress over `previous`, touching only what changed so recording a step never
    /// materializes a "completed version 0" entry. A cleared resume point is stored as an absent
    /// key, the same shape a fresh install has.
    func save(to userDefaults: UserDefaults, replacing previous: OnboardingProgress) {
        if completedVersion != previous.completedVersion {
            userDefaults.set(completedVersion, forKey: Self.completedVersionKey)
        }
        if furthestStepIndex == 0 {
            userDefaults.removeObject(forKey: Self.furthestStepKey)
        } else if furthestStepIndex != previous.furthestStepIndex {
            userDefaults.set(furthestStepIndex, forKey: Self.furthestStepKey)
        }
    }
}
