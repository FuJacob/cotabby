import XCTest
@testable import Cotabby

/// Tests for the onboarding resume and version rules. These decide whether a user sees the wizard
/// at launch and where it opens, including the relaunch-mid-onboarding case from issue #314.
@MainActor
final class OnboardingProgressTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = IsolatedUserDefaults.make()
    }

    override func tearDown() {
        defaults = nil
        super.tearDown()
    }

    private func progress(completedVersion: Int = 0, furthestStepIndex: Int = 0) -> OnboardingProgress {
        OnboardingProgress(completedVersion: completedVersion, furthestStepIndex: furthestStepIndex)
    }

    /// Applies a transition the way the coordinator does: load, transform, save over what was loaded.
    private func apply(_ transition: (OnboardingProgress) -> OnboardingProgress) {
        let current = OnboardingProgress.load(from: defaults)
        transition(current).save(to: defaults, replacing: current)
    }

    // MARK: - Status

    func test_freshUser_hasNeverCompletedAndStartsAtWelcome() {
        let fresh = OnboardingProgress.load(from: defaults)

        XCTAssertEqual(fresh, progress())
        XCTAssertEqual(fresh.status, .neverCompleted)
        XCTAssertFalse(fresh.isCompleted)
        XCTAssertFalse(fresh.isReturningUser)
        XCTAssertEqual(fresh.resumeStep, .welcome)
    }

    func test_olderCompletedVersion_reshowsTheWizardToAReturningUser() {
        let upgraded = progress(completedVersion: OnboardingProgress.currentVersion - 1)

        XCTAssertEqual(upgraded.status, .completedEarlierVersion)
        XCTAssertFalse(upgraded.isCompleted, "a version bump must show the revamped flow again")
        XCTAssertTrue(upgraded.isReturningUser, "their tuned settings must not be overwritten")
    }

    func test_currentOrNewerCompletedVersion_keepsTheWizardHidden() {
        for version in [OnboardingProgress.currentVersion, OnboardingProgress.currentVersion + 1] {
            let done = progress(completedVersion: version)
            XCTAssertEqual(done.status, .completedCurrentVersion)
            XCTAssertTrue(done.isCompleted)
            XCTAssertTrue(done.isReturningUser)
        }
    }

    // MARK: - Resume point

    func test_resumeStep_isTheFurthestStepReached() {
        XCTAssertEqual(progress(furthestStepIndex: WelcomeStep.template.rawValue).resumeStep, .template)
    }

    func test_resumeStep_fallsBackToWelcomeForAnIndexThatNamesNoStep() {
        XCTAssertEqual(progress(furthestStepIndex: -1).resumeStep, .welcome)
        XCTAssertEqual(progress(furthestStepIndex: WelcomeStep.allCases.count).resumeStep, .welcome)
    }

    func test_reaching_advancesButNeverLowersTheResumePoint() {
        let atTemplate = progress().reaching(.permissions).reaching(.template)
        XCTAssertEqual(atTemplate.resumeStep, .template)

        // Stepping back to an earlier page must not move the resume point back with it.
        XCTAssertEqual(atTemplate.reaching(.permissions), atTemplate)
        XCTAssertEqual(atTemplate.reaching(.template), atTemplate)
    }

    func test_reaching_doesNotTouchTheCompletedVersion() {
        let returning = progress(completedVersion: 1).reaching(.keybind)

        XCTAssertEqual(returning.completedVersion, 1)
        XCTAssertEqual(returning.resumeStep, .keybind)
    }

    func test_completing_stampsTheCurrentVersionAndClearsTheResumePoint() {
        let finished = progress(completedVersion: 1, furthestStepIndex: WelcomeStep.done.rawValue).completing()

        XCTAssertEqual(finished.completedVersion, OnboardingProgress.currentVersion)
        XCTAssertTrue(finished.isCompleted)
        XCTAssertEqual(finished.resumeStep, .welcome, "reopening the wizard later starts from the top")
    }

    // MARK: - Persistence

    func test_keys_areThePersistedOnes() {
        // Renaming either key silently resets every user's onboarding state.
        XCTAssertEqual(OnboardingProgress.completedVersionKey, "cotabbyOnboardingCompletedVersion")
        XCTAssertEqual(OnboardingProgress.furthestStepKey, "cotabbyOnboardingProgressStep2")
    }

    func test_midFlowRelaunch_resumesAtTheFurthestStep() {
        // Issue #314: granting a permission forces a relaunch before the wizard is finished.
        apply { $0.reaching(.welcome) }
        apply { $0.reaching(.permissions) }

        let relaunched = OnboardingProgress.load(from: defaults)

        XCTAssertFalse(relaunched.isCompleted)
        XCTAssertEqual(relaunched.resumeStep, .permissions)
        XCTAssertEqual(defaults.integer(forKey: OnboardingProgress.furthestStepKey), 1)
    }

    func test_recordingAStep_doesNotMaterializeACompletedVersionEntry() {
        apply { $0.reaching(.template) }

        XCTAssertNil(defaults.object(forKey: OnboardingProgress.completedVersionKey))
    }

    func test_steppingBack_leavesTheStoredResumePointAlone() {
        apply { $0.reaching(.personalize) }
        apply { $0.reaching(.template) }

        XCTAssertEqual(defaults.integer(forKey: OnboardingProgress.furthestStepKey), WelcomeStep.personalize.rawValue)
    }

    func test_completion_persistsTheVersionAndRemovesTheResumeKey() {
        apply { $0.reaching(.done) }
        apply { $0.completing() }

        XCTAssertEqual(defaults.integer(forKey: OnboardingProgress.completedVersionKey), OnboardingProgress.currentVersion)
        XCTAssertNil(defaults.object(forKey: OnboardingProgress.furthestStepKey))
        XCTAssertTrue(OnboardingProgress.load(from: defaults).isCompleted)
    }

    func test_storedOlderVersion_loadsAsAReturningUserWhoSeesTheWizardAgain() {
        defaults.set(1, forKey: OnboardingProgress.completedVersionKey)

        let loaded = OnboardingProgress.load(from: defaults)

        XCTAssertEqual(loaded.status, .completedEarlierVersion)
        XCTAssertEqual(loaded.resumeStep, .welcome)
    }
}
