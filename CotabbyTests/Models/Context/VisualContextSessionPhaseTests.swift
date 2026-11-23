import XCTest
@testable import Cotabby

/// Transition tests for the visual-context session lifecycle. The published status and the
/// excerpt handed to prompts are derived from the phase, so these lock the rules that keep stale
/// screen text out of a prompt and stale async work out of the next session.
final class VisualContextSessionPhaseTests: XCTestCase {
    private let permissionReason = "Screen Recording permission is required."
    private let excerpt = VisualContextExcerpt(text: "Project agenda and deadline")

    private func surface(url: String? = nil, title: String? = nil, sequence: UInt64 = 1) -> FocusedInputSessionIdentity {
        FocusedInputSessionIdentity(
            processIdentifier: 123,
            bundleIdentifier: "com.example.TestApp",
            focusChangeSequence: sequence,
            focusedURLString: url,
            windowTitle: title
        )
    }

    private func makeSession(surface: FocusedInputSessionIdentity? = nil) -> VisualContextSession {
        VisualContextSession(
            id: UUID(),
            field: FocusedInputIdentity(elementIdentifier: "field", focusChangeSequence: 1),
            surface: surface ?? self.surface()
        )
    }

    private func readyPhase(_ session: VisualContextSession, capturedAt: TimeInterval = 10) -> VisualContextSessionPhase {
        .ready(session, excerpt: excerpt, capturedAt: capturedAt)
    }

    // MARK: - Derived state

    func test_idleAndSettlingPublishIdleWithNoSession() {
        let field = FocusedInputIdentity(elementIdentifier: "field", focusChangeSequence: 1)
        let settling = VisualContextSessionPhase.settling(field: field, surface: surface())

        XCTAssertEqual(VisualContextSessionPhase.idle.status, .idle)
        XCTAssertEqual(settling.status, .idle)
        XCTAssertNil(settling.session)
        XCTAssertEqual(settling.settlingField, field)
        XCTAssertEqual(settling.surface, surface())
        XCTAssertNil(VisualContextSessionPhase.idle.surface)
    }

    func test_onlyReadyCarriesAnExcerpt() {
        let session = makeSession()
        let withoutExcerpt: [VisualContextSessionPhase] = [
            .idle,
            .blockedOnPermission(session, reason: permissionReason),
            .capturing(session, stage: .capturingScreen),
            .unavailable(session, reason: "Too little text"),
            .failed(session, reason: "Capture broke")
        ]
        for phase in withoutExcerpt {
            XCTAssertNil(phase.excerpt, "\(phase.status)")
            XCTAssertNil(phase.excerptCapturedAt, "\(phase.status)")
        }

        let ready = readyPhase(session, capturedAt: 42)
        XCTAssertEqual(ready.excerpt, excerpt)
        XCTAssertEqual(ready.excerptCapturedAt, 42)
        XCTAssertEqual(ready.status, .ready)
    }

    func test_statusKeepsTheReasonForEveryNonReadyOutcome() {
        let session = makeSession()

        XCTAssertEqual(VisualContextSessionPhase.capturing(session, stage: .capturingScreen).status, .capturing)
        XCTAssertEqual(VisualContextSessionPhase.capturing(session, stage: .extractingText).status, .extractingText)
        XCTAssertEqual(VisualContextSessionPhase.unavailable(session, reason: "Too little text").status, .unavailable("Too little text"))
        XCTAssertEqual(VisualContextSessionPhase.failed(session, reason: "Capture broke").status, .failed("Capture broke"))
        // A blocked session reads as unavailable to the menu; only the coordinator tells them apart.
        XCTAssertEqual(
            VisualContextSessionPhase.blockedOnPermission(session, reason: permissionReason).status,
            .unavailable(permissionReason)
        )
    }

    // MARK: - Launch

    func test_launchCapturesWithPermissionAndParksWithout() {
        let session = makeSession()

        var granted = VisualContextSessionPhase.idle
        granted.launch(session, hasPermission: true, permissionMissingReason: permissionReason)
        XCTAssertEqual(granted, .capturing(session, stage: .capturingScreen))
        XCTAssertFalse(granted.isBlockedOnPermission)

        var missing = VisualContextSessionPhase.idle
        missing.launch(session, hasPermission: false, permissionMissingReason: permissionReason)
        XCTAssertEqual(missing, .blockedOnPermission(session, reason: permissionReason))
        XCTAssertTrue(missing.isBlockedOnPermission)
    }

    // MARK: - Capture progress and outcomes

    func test_progressMovesANonReadySessionThroughItsStages() {
        let session = makeSession()
        var phase = VisualContextSessionPhase.unavailable(session, reason: "Too little text")

        XCTAssertTrue(phase.captureProgressed(to: .capturingScreen, sessionID: session.id))
        XCTAssertTrue(phase.captureProgressed(to: .extractingText, sessionID: session.id))

        XCTAssertEqual(phase, .capturing(session, stage: .extractingText))
    }

    func test_progressFromARefreshDoesNotDisturbAReadyExcerpt() {
        let session = makeSession()
        var phase = readyPhase(session)

        XCTAssertFalse(phase.captureProgressed(to: .capturingScreen, sessionID: session.id))

        XCTAssertEqual(phase, readyPhase(session))
    }

    func test_adoptingAnExcerptMakesTheSessionReadyAndARefreshReplacesIt() {
        let session = makeSession()
        var phase = VisualContextSessionPhase.capturing(session, stage: .extractingText)

        XCTAssertTrue(phase.adopt(excerpt, capturedAt: 10, sessionID: session.id))
        XCTAssertEqual(phase, readyPhase(session, capturedAt: 10))

        let refreshed = VisualContextExcerpt(text: "A different conversation")
        XCTAssertTrue(phase.adopt(refreshed, capturedAt: 13, sessionID: session.id))
        XCTAssertEqual(phase, .ready(session, excerpt: refreshed, capturedAt: 13))
    }

    func test_everyFailureOutcomeDropsTheExcerpt() {
        let session = makeSession()

        var unavailable = readyPhase(session)
        XCTAssertTrue(unavailable.markUnavailable(reason: "Screen context expired", sessionID: session.id))
        XCTAssertEqual(unavailable, .unavailable(session, reason: "Screen context expired"))

        var failed = readyPhase(session)
        XCTAssertTrue(failed.markFailed(reason: "Capture broke", sessionID: session.id))
        XCTAssertEqual(failed, .failed(session, reason: "Capture broke"))

        var blocked = readyPhase(session)
        XCTAssertTrue(blocked.markBlockedOnPermission(reason: permissionReason, sessionID: session.id))
        XCTAssertEqual(blocked, .blockedOnPermission(session, reason: permissionReason))
    }

    func test_workFromAnotherSessionCannotChangeTheCurrentOne() {
        let session = makeSession()
        let stale = UUID()
        var phase = readyPhase(session)

        XCTAssertFalse(phase.captureProgressed(to: .extractingText, sessionID: stale))
        XCTAssertFalse(phase.adopt(VisualContextExcerpt(text: "Other field"), capturedAt: 99, sessionID: stale))
        XCTAssertFalse(phase.markUnavailable(reason: "stale", sessionID: stale))
        XCTAssertFalse(phase.markFailed(reason: "stale", sessionID: stale))
        XCTAssertFalse(phase.markBlockedOnPermission(reason: "stale", sessionID: stale))
        phase.learnSurfaceFacts(from: surface(title: "Other"), captured: excerpt, sessionID: stale)

        XCTAssertEqual(phase, readyPhase(session))
    }

    func test_lateWorkAfterTheSessionEndedIsIgnored() {
        let session = makeSession()
        var idle = VisualContextSessionPhase.idle
        var settling = VisualContextSessionPhase.settling(field: session.field, surface: session.surface)

        XCTAssertFalse(idle.adopt(excerpt, capturedAt: 1, sessionID: session.id))
        XCTAssertFalse(settling.markFailed(reason: "late", sessionID: session.id))

        XCTAssertEqual(idle, .idle)
        XCTAssertEqual(settling, .settling(field: session.field, surface: session.surface))
    }

    // MARK: - Surface facts

    func test_surfaceFactsAreLearnedFromTheCaptureThatProducedTheExcerptInUse() {
        let session = makeSession(surface: surface(url: nil, title: nil))
        var phase = readyPhase(session)

        phase.learnSurfaceFacts(from: surface(title: "Chat one"), captured: excerpt, sessionID: session.id)

        XCTAssertEqual(phase.session?.surface, surface(title: "Chat one"))
        XCTAssertEqual(phase.excerpt, excerpt)
    }

    func test_surfaceFactsAreNotLearnedForAnExcerptThatIsNotTheOneInUse() {
        // The refresh's reading was judged OCR jitter and the earlier excerpt was kept, so the
        // facts this capture observed do not describe the pixels behind the excerpt in use.
        let session = makeSession(surface: surface(url: nil, title: nil))
        var phase = readyPhase(session)

        phase.learnSurfaceFacts(
            from: surface(title: "Chat one"),
            captured: VisualContextExcerpt(text: "Project agenda and deadIine"),
            sessionID: session.id
        )

        XCTAssertEqual(phase, readyPhase(session))
    }

    func test_aKnownSurfaceFactIsNeverOverwritten() {
        let session = makeSession(surface: surface(title: "Chat one"))
        var phase = readyPhase(session)

        phase.learnSurfaceFacts(from: surface(title: "Chat two"), captured: excerpt, sessionID: session.id)

        XCTAssertEqual(phase, readyPhase(session))
    }

    func test_surfaceFactsAreOnlyLearnedWhileReady() {
        let session = makeSession(surface: surface(title: nil))
        var phase = VisualContextSessionPhase.unavailable(session, reason: "Too little text")

        phase.learnSurfaceFacts(from: surface(title: "Chat one"), captured: excerpt, sessionID: session.id)

        XCTAssertEqual(phase, .unavailable(session, reason: "Too little text"))
    }
}
