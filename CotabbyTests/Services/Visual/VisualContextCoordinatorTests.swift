import XCTest
@testable import Cotabby

/// Exercises the field-scoped state machine with no real screenshot or TCC permission access.
@MainActor
final class VisualContextCoordinatorTests: XCTestCase {
    func test_refreshUsesLatestFieldTextAndOnlyNotifiesWhenExcerptChanges() async throws {
        let generator = StubVisualContextGenerator()
        let coordinator = makeCoordinator(generator)
        var live = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "First draft")
        coordinator.refreshContextProvider = { live }
        var notifications = 0
        coordinator.onInjectedContextReady = { _ in notifications += 1 }
        coordinator.startSessionIfNeeded(for: live, configuration: .local)
        defer { coordinator.cancel(resetState: true) }
        try await waitUntil { generator.contexts.count >= 1 && coordinator.status == .ready }
        live = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Updated draft")
        try await waitUntil { generator.contexts.count >= 2 }
        XCTAssertEqual(generator.contexts.last?.precedingText, "Updated draft")
        XCTAssertEqual(notifications, 1, "Identical screen text must not restart predictions every refresh")
        generator.text = "A new message arrived"
        try await waitUntil { notifications == 2 }
        XCTAssertEqual(coordinator.latestExcerpt, generator.text)
    }

    func test_permissionRevocationStopsRefreshAndClearsExcerpt() async throws {
        let generator = StubVisualContextGenerator()
        var allowed = true
        let coordinator = makeCoordinator(generator, permission: { allowed })
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot()
        coordinator.refreshContextProvider = { snapshot }
        coordinator.startSessionIfNeeded(for: snapshot, configuration: .local)
        defer { coordinator.cancel(resetState: true) }
        try await waitUntil { coordinator.status == .ready }
        allowed = false
        try await waitUntil { coordinator.status == .idle }
        XCTAssertNil(coordinator.latestExcerpt)
        XCTAssertEqual(generator.contexts.count, 1)
    }

    func test_newFieldCannotInheritPreviousFieldExcerpt() async throws {
        let generator = StubVisualContextGenerator()
        let coordinator = makeCoordinator(generator)
        var live = CotabbyTestFixtures.focusedInputSnapshot()
        coordinator.refreshContextProvider = { live }
        coordinator.startSessionIfNeeded(for: live, configuration: .local)
        defer { coordinator.cancel(resetState: true) }
        try await waitUntil { coordinator.status == .ready }
        live = CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "other", focusChangeSequence: 2)
        try await waitUntil { coordinator.status == .idle }
        XCTAssertNil(coordinator.latestExcerpt)
        XCTAssertEqual(generator.contexts.count, 1)
    }

    func test_keepsReadyExcerptWhileRefreshIsSuspendedAndRejectsLateResultAfterCancel() async throws {
        let generator = StubVisualContextGenerator()
        let coordinator = makeCoordinator(generator)
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot()
        coordinator.refreshContextProvider = { snapshot }
        coordinator.startSessionIfNeeded(for: snapshot, configuration: .local)
        try await waitUntil { coordinator.status == .ready }
        generator.suspendNext = true
        try await waitUntil { generator.pending != nil }
        XCTAssertEqual(coordinator.status, .ready)
        XCTAssertEqual(coordinator.latestExcerpt, "Project agenda and deadline")
        coordinator.cancel(resetState: true)
        generator.pending?.resume()
        generator.pending = nil
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertNil(coordinator.latestExcerpt)
    }

    func test_endpointRefreshKeepsOriginalCropAndLimits() async throws {
        let generator = StubVisualContextGenerator()
        let coordinator = makeCoordinator(generator)
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot()
        coordinator.refreshContextProvider = { snapshot }
        coordinator.startSessionIfNeeded(for: snapshot, configuration: .default)
        defer { coordinator.cancel(resetState: true) }
        try await waitUntil { coordinator.status == .ready }
        try await waitUntil { generator.contexts.count >= 2 }
        XCTAssertTrue(generator.configurations.allSatisfy { $0 == .default })
    }

    func test_reusedComposerClearsPublishedExcerptDuringNavigationSettleDelay() async throws {
        let generator = StubVisualContextGenerator()
        let coordinator = makeCoordinator(generator)
        var live = CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "First chat")
        coordinator.refreshContextProvider = { live }
        var published: String?
        coordinator.onStateChange = { _, excerpt in published = excerpt }
        coordinator.startSessionIfNeeded(for: live, configuration: .local)
        defer { coordinator.cancel(resetState: true) }
        try await waitUntil { coordinator.status == .ready }
        XCTAssertNotNil(published)

        // Even an unchanged AX handle, sequence, text and frame cannot hide a new conversation.
        live = CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Second chat")
        coordinator.startSessionIfNeeded(for: live, configuration: .local)
        XCTAssertNil(published)
        XCTAssertNil(coordinator.latestExcerpt)
        XCTAssertNil(coordinator.excerpt(for: FocusedInputContext(snapshot: live, generation: 1)))
        generator.text = "Current conversation"
        try await waitUntil { coordinator.latestExcerpt == "Current conversation" }
    }

    func test_expiredExcerptIsUnusableWhileRefreshIsSuspended() async throws {
        let generator = StubVisualContextGenerator()
        var uptime: TimeInterval = 10
        let coordinator = VisualContextCoordinator(
            screenshotContextGenerator: generator, screenRecordingPermissionProvider: { true },
            refreshIntervalNanoseconds: 30_000_000, now: { uptime }
        )
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot()
        coordinator.refreshContextProvider = { snapshot }
        coordinator.startSessionIfNeeded(for: snapshot, configuration: .local)
        defer { coordinator.cancel(resetState: true); generator.pending?.resume(); generator.pending = nil }
        try await waitUntil { coordinator.status == .ready }
        generator.suspendNext = true
        try await waitUntil { generator.pending != nil }
        uptime += 6
        XCTAssertNil(coordinator.excerpt(for: FocusedInputContext(snapshot: snapshot, generation: 1)))
        XCTAssertNil(coordinator.latestExcerpt)
        // The completed OCR is also old: completion time cannot reset the age of captured pixels.
        generator.pending?.resume()
        generator.pending = nil
        try await waitUntil {
            coordinator.status == .unavailable("Screen context expired before recognition completed.")
        }
        XCTAssertNil(coordinator.latestExcerpt)
    }

    func test_timerExpiresExcerptWithoutAnotherRequest() async throws {
        let generator = StubVisualContextGenerator()
        let coordinator = VisualContextCoordinator(
            screenshotContextGenerator: generator, screenRecordingPermissionProvider: { true },
            excerptLifetimeNanoseconds: 80_000_000
        )
        coordinator.startSessionIfNeeded(for: CotabbyTestFixtures.focusedInputSnapshot())
        defer { coordinator.cancel(resetState: true) }
        try await waitUntil { coordinator.status == .ready }
        try await waitUntil { coordinator.latestExcerpt == nil }
        XCTAssertEqual(coordinator.status, .unavailable("Screen context expired; waiting for a fresh capture."))
    }

    func test_lateOCRFromPreviousChatCannotPublishIntoReplacementSession() async throws {
        let generator = StubVisualContextGenerator()
        let coordinator = makeCoordinator(generator)
        var live = CotabbyTestFixtures.focusedInputSnapshot()
        coordinator.refreshContextProvider = { live }
        generator.suspendNext = true
        coordinator.startSessionIfNeeded(for: live, configuration: .default)
        defer { coordinator.cancel(resetState: true); generator.pending?.resume(); generator.pending = nil }
        try await waitUntil { generator.pending != nil }
        live = CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2)
        coordinator.startSessionIfNeeded(for: live, configuration: .default)
        generator.pending?.resume()
        generator.pending = nil
        await Task.yield()
        XCTAssertNil(coordinator.latestExcerpt)
        generator.text = "New chat facts"
        try await waitUntil { coordinator.latestExcerpt == "New chat facts" }
    }

    func test_secureFieldNeverStartsCapture() async throws {
        let generator = StubVisualContextGenerator()
        let coordinator = makeCoordinator(generator)
        coordinator.startSessionIfNeeded(for: CotabbyTestFixtures.focusedInputSnapshot(isSecure: true), configuration: .local)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(generator.contexts.isEmpty)
        XCTAssertEqual(coordinator.status, .idle)
    }

    private func makeCoordinator(
        _ generator: StubVisualContextGenerator,
        permission: @escaping @MainActor () -> Bool = { true }
    ) -> VisualContextCoordinator {
        VisualContextCoordinator(
            screenshotContextGenerator: generator, screenRecordingPermissionProvider: permission,
            refreshIntervalNanoseconds: 30_000_000
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Visual-context state did not settle")
    }
}

@MainActor
private final class StubVisualContextGenerator: ScreenshotContextGenerating {
    var contexts: [FocusedInputSnapshot] = []
    var configurations: [VisualContextConfiguration] = []
    var text = "Project agenda and deadline"
    var suspendNext = false
    var pending: CheckedContinuation<Void, Never>?

    func generateContext(
        for context: FocusedInputSnapshot,
        configuration: VisualContextConfiguration?,
        onStatusChange: (@MainActor @Sendable (VisualContextStatus) -> Void)?
    ) async throws -> VisualContextExcerpt {
        contexts.append(context)
        configurations.append(configuration ?? .default)
        onStatusChange?(.capturing)
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { pending = $0 }
        }
        return VisualContextExcerpt(text: text)
    }
}
