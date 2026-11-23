import Foundation

/// One field-scoped screenshot-context session: which focus event it belongs to and the surface
/// (app, URL, window title) it was captured on.
nonisolated struct VisualContextSession: Equatable, Sendable {
    /// Distinguishes this session from a later one for the same field, so async capture work that
    /// outlives its session cannot write into the next.
    let id: UUID
    let field: FocusedInputIdentity
    /// Surface facts can change while an app reuses its composer and AX handle (a chat switch).
    /// Facts the session started without are filled in as captures observe them; known facts are
    /// never overwritten.
    var surface: FocusedInputSessionIdentity
}

/// The whole lifecycle of `VisualContextCoordinator`'s single session as one value.
///
/// The published `VisualContextStatus` and the excerpt handed to prompts are both derived from
/// this, so they cannot drift from the session they describe: an excerpt exists only in `ready`,
/// and "blocked on Screen Recording" is its own case rather than a message to pattern-match.
///
/// Every transition that comes from async capture work takes the session id it was started for and
/// does nothing when a different session (or none) is current.
nonisolated enum VisualContextSessionPhase: Equatable, Sendable {
    nonisolated enum CaptureStage: Equatable, Sendable {
        case capturingScreen
        case extractingText
    }

    case idle
    /// A field is waiting out the settle delay before its capture pipeline launches.
    case settling(field: FocusedInputIdentity, surface: FocusedInputSessionIdentity)
    /// The session exists but Screen Recording permission is missing. A grant observed for the
    /// same field restarts it instead of being ignored as a duplicate start.
    case blockedOnPermission(VisualContextSession, reason: String)
    /// A capture is running and no usable excerpt exists yet.
    case capturing(VisualContextSession, stage: CaptureStage)
    /// An excerpt is available. Background refreshes keep this phase until they produce a result,
    /// so capture and OCR never gate generation. `capturedAt` is monotonic uptime taken before the
    /// capture started: a slow recognition cannot renew old pixels.
    case ready(VisualContextSession, excerpt: VisualContextExcerpt, capturedAt: TimeInterval)
    case unavailable(VisualContextSession, reason: String)
    case failed(VisualContextSession, reason: String)

    // MARK: - Derived state

    var session: VisualContextSession? {
        switch self {
        case .idle, .settling:
            return nil
        case .blockedOnPermission(let session, _), .capturing(let session, _), .ready(let session, _, _),
             .unavailable(let session, _), .failed(let session, _):
            return session
        }
    }

    var status: VisualContextStatus {
        switch self {
        case .idle, .settling:
            return .idle
        case .capturing(_, .capturingScreen):
            return .capturing
        case .capturing(_, .extractingText):
            return .extractingText
        case .ready:
            return .ready
        case .blockedOnPermission(_, let reason), .unavailable(_, let reason):
            return .unavailable(reason)
        case .failed(_, let reason):
            return .failed(reason)
        }
    }

    var excerpt: VisualContextExcerpt? {
        if case .ready(_, let excerpt, _) = self { return excerpt }
        return nil
    }

    var excerptCapturedAt: TimeInterval? {
        if case .ready(_, _, let capturedAt) = self { return capturedAt }
        return nil
    }

    var isBlockedOnPermission: Bool {
        if case .blockedOnPermission = self { return true }
        return false
    }

    /// The field waiting out the settle delay, if any.
    var settlingField: FocusedInputIdentity? {
        if case .settling(let field, _) = self { return field }
        return nil
    }

    /// The surface the current or pending session belongs to.
    var surface: FocusedInputSessionIdentity? {
        if case .settling(_, let surface) = self { return surface }
        return session?.surface
    }

    // MARK: - Transitions

    /// A settled field launches its session: capturing when Screen Recording is granted, parked on
    /// the missing permission otherwise.
    mutating func launch(_ session: VisualContextSession, hasPermission: Bool, permissionMissingReason: String) {
        self = hasPermission
            ? .capturing(session, stage: .capturingScreen)
            : .blockedOnPermission(session, reason: permissionMissingReason)
    }

    /// Progress from a running capture. Ignored while an excerpt is available: a background
    /// refresh must not make a ready session look like it is starting over.
    mutating func captureProgressed(to stage: CaptureStage, sessionID: UUID) -> Bool {
        guard let session = session, session.id == sessionID, excerpt == nil else { return false }
        self = .capturing(session, stage: stage)
        return true
    }

    /// A capture produced an excerpt for the current session.
    mutating func adopt(_ excerpt: VisualContextExcerpt, capturedAt: TimeInterval, sessionID: UUID) -> Bool {
        guard let session = session, session.id == sessionID else { return false }
        self = .ready(session, excerpt: excerpt, capturedAt: capturedAt)
        return true
    }

    /// The remaining outcomes all drop any excerpt: a failed or blank capture, or an expired
    /// excerpt, must not leave an old conversation masquerading as current context.
    mutating func markUnavailable(reason: String, sessionID: UUID) -> Bool {
        guard let session = session, session.id == sessionID else { return false }
        self = .unavailable(session, reason: reason)
        return true
    }

    mutating func markFailed(reason: String, sessionID: UUID) -> Bool {
        guard let session = session, session.id == sessionID else { return false }
        self = .failed(session, reason: reason)
        return true
    }

    mutating func markBlockedOnPermission(reason: String, sessionID: UUID) -> Bool {
        guard let session = session, session.id == sessionID else { return false }
        self = .blockedOnPermission(session, reason: reason)
        return true
    }

    /// Learns surface facts the session started without, but only from the context `captured` was
    /// taken under and only while `captured` is the excerpt in use. The excerpt's pixels belong to
    /// that read, so exposing it to a request carrying the now-known title or URL cannot leak an
    /// earlier chat's text. An excerpt captured while a fact was unknown never gains that fact.
    mutating func learnSurfaceFacts(
        from observed: FocusedInputSessionIdentity,
        captured: VisualContextExcerpt,
        sessionID: UUID
    ) {
        guard case .ready(var session, let excerpt, let capturedAt) = self,
              session.id == sessionID,
              excerpt == captured,
              observed.continues(session.surface) else {
            return
        }
        session.surface = session.surface.filled(from: observed)
        self = .ready(session, excerpt: excerpt, capturedAt: capturedAt)
    }
}
