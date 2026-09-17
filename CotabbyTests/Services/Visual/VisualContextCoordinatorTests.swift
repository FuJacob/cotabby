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

    func test_endpointKeepsFocusOnlyCapture() async throws {
        let generator = StubVisualContextGenerator()
        let coordinator = makeCoordinator(generator)
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot()
        coordinator.refreshContextProvider = { snapshot }
        coordinator.startSessionIfNeeded(for: snapshot, configuration: .default)
        defer { coordinator.cancel(resetState: true) }
        try await waitUntil { coordinator.status == .ready }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(generator.contexts.count, 1)
        XCTAssertEqual(generator.configurations, [.default])
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
