import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Tracks Cotabby's own synthetic key events so inserted suggestions do not recursively trigger
/// the input-monitoring pipeline and cause bogus follow-up completions.
///
/// Think of this as a tiny "ignore my own write" guard. When Cotabby injects accepted text back into
/// the focused app, the global event tap would otherwise observe those synthetic key events and
/// treat them like fresh user typing.
@MainActor
final class InputSuppressionController {
    private var remainingKeyDownSuppressions = 0
    private var suppressionExpiry = Date.distantPast

    // All stored state is plain value types, safe to release from any thread. The nonisolated
    // deinit avoids the isolated-deinit back-deploy double-free that crashes app-hosted tests
    // when a @MainActor class with stored properties deallocates (see SuggestionSettingsModel).
    nonisolated deinit {}

    /// Stamped onto Cotabby's synthetic insertion events so any tap can recognize them by identity,
    /// not just the listen-only observer's countdown. The consuming accept tap needs this: the
    /// inserter posts with `virtualKey: 0`, so if a user binds the accept key to keyCode 0 the accept
    /// tap would otherwise treat our own inserted text as accept-key presses and swallow the
    /// insertion.
    ///
    /// Drawn at random once per launch (a static `let` initializes exactly once per process) rather
    /// than compiled in: a fixed value is readable from the public binary, and any process that
    /// stamped it on its own key events would have them pass every Cotabby tap unobserved, neither
    /// counted as typing nor treated as an accept key. Never 0, the value real events carry here.
    static let syntheticEventUserData = Int64.random(in: 1...Int64.max)

    /// The pid the window server reports as the source of events this process posts.
    private static let ownProcessID = Int64(ProcessInfo.processInfo.processIdentifier)

    /// Arms a short-lived suppression window for the synthetic keydown events Cotabby is about to post.
    ///
    /// Accumulates instead of overwriting: event-tap delivery is asynchronous, so a rapid accept
    /// burst arms the next chunk's suppressions while the previous chunk's synthetic keydowns are
    /// still in flight. Overwriting reset the counter mid-burst, the earlier chunk's events drained
    /// the new tokens, and the later chunk's tail leaked into the observer as "user typing" —
    /// which invalidated the very suggestion the user was busy accepting. The expiry (refreshed on
    /// each arm) still bounds the accumulated count to roughly one second of inserts.
    func registerSyntheticInsertion(expectedKeyDownCount: Int) {
        if Date() > suppressionExpiry {
            remainingKeyDownSuppressions = 0
        }
        remainingKeyDownSuppressions += max(expectedKeyDownCount, 0)
        suppressionExpiry = Date().addingTimeInterval(1.0)
        CotabbyLogger.app.trace("Suppression armed for \(expectedKeyDownCount) synthetic key event(s)")
    }

    /// Consumes one pending suppression token if the current event still falls inside the expiry window.
    /// The expiry protects against stale suppression accidentally swallowing a real later keystroke.
    func consumeIfNeeded() -> Bool {
        guard remainingKeyDownSuppressions > 0 else {
            return false
        }

        guard Date() <= suppressionExpiry else {
            remainingKeyDownSuppressions = 0
            return false
        }

        remainingKeyDownSuppressions -= 1
        return true
    }

    /// Tags an event Cotabby is about to post so taps can ignore it by identity.
    func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
    }

    /// True when the event carries Cotabby's synthetic-insertion marker and was posted by this
    /// process.
    func isSynthetic(_ event: CGEvent) -> Bool {
        let userData = event.getIntegerValueField(.eventSourceUserData)
        // Every real keystroke lands here; leave without the pid read when the marker is absent.
        guard userData == Self.syntheticEventUserData else {
            return false
        }
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        if Self.isSyntheticSignature(
            userData: userData,
            sourcePID: sourcePID,
            marker: Self.syntheticEventUserData,
            ownPID: Self.ownProcessID
        ) {
            return true
        }
        // Only reachable if another process reproduced this launch's marker, or if the system
        // reports an unexpected source pid for Cotabby's own posts. The second would make our
        // inserted text read as typing, so it is worth seeing in Console.
        CotabbyLogger.app.warning("Ignored the synthetic-event marker on an event from pid \(sourcePID)")
        return false
    }

    /// Pure form of `isSynthetic(_:)`, split out so the rule is testable without posting events.
    ///
    /// The source-pid check is a second, cheap layer behind the per-launch marker: an event another
    /// process posts carries that process's pid. A pid of 0 is still accepted with a matching marker
    /// so that Cotabby's own posts are never refused if the system leaves the field unset for them;
    /// that costs nothing, because a process that could choose the pid field could equally choose
    /// Cotabby's pid. Events without the marker are never affected, so synthetic keys from
    /// remappers, automation tools, and remote-desktop clients keep working as accept keys.
    static func isSyntheticSignature(userData: Int64, sourcePID: Int64, marker: Int64, ownPID: Int64) -> Bool {
        guard marker != 0, userData == marker else {
            return false
        }
        return sourcePID == ownPID || sourcePID == 0
    }
}
