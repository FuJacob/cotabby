import CoreGraphics
import Foundation

/// Describes one bounded prediction for the words after an offered word ending or correction.
///
/// The coordinator owns this value only while that offer is relevant. `sourceSnapshot` identifies
/// the offer, `targetSnapshot` describes the exact edit the user may commit, and `requestSnapshot`
/// adds a virtual word boundary when necessary so the engine predicts following words instead of
/// extending the completed word again. No virtual character is inserted into the editor. Keeping
/// these pure transformations together lets async orchestration validate a result without guessing
/// which text, field, or caret the prediction belongs to.
nonisolated struct SuggestionContinuationPlan: Equatable, Sendable {
    let sourceSnapshot: FocusedInputSnapshot
    let targetSnapshot: FocusedInputSnapshot
    let requestSnapshot: FocusedInputSnapshot
    let joiningSeparator: String

    static func completing(_ suffix: String, in snapshot: FocusedInputSnapshot) -> Self? {
        guard isEligible(snapshot), !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Self(source: snapshot, target: SpeculativeAcceptanceContext.optimisticSnapshot(
            after: snapshot, inserting: suffix
        ))
    }

    static func correcting(_ replacement: TypoCorrectionReplacement, in snapshot: FocusedInputSnapshot) -> Self? {
        guard isEligible(snapshot),
              !replacement.replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let target = SpeculativeAcceptanceContext.optimisticSnapshot(after: snapshot, replacing: replacement) else {
            return nil
        }
        return Self(source: snapshot, target: target)
    }

    private init(source: FocusedInputSnapshot, target: FocusedInputSnapshot) {
        sourceSnapshot = source
        targetSnapshot = target
        joiningSeparator = target.precedingText.last?.isWhitespace == true ? "" : " "
        requestSnapshot = SpeculativeAcceptanceContext.optimisticSnapshot(after: target, inserting: joiningSeparator)
    }

    func matchesSource(_ snapshot: FocusedInputSnapshot) -> Bool {
        Self.matches(snapshot, expected: sourceSnapshot)
    }

    func matchesTarget(_ snapshot: FocusedInputSnapshot) -> Bool {
        Self.matches(snapshot, expected: targetSnapshot)
    }

    /// The user or auto-space preference may commit the boundary we originally added only to the
    /// request. This is the sole accepted target variation; callers then consume its leading space.
    func matchesTargetWithJoiningSeparator(_ snapshot: FocusedInputSnapshot) -> Bool {
        !joiningSeparator.isEmpty && Self.matches(snapshot, expected: requestSnapshot)
    }

    /// Converts request-relative output back into text that may follow the actual committed edit.
    /// The virtual space belongs to the prediction only until we prepend it here. Existing model
    /// newlines remain meaningful, and indentation after a newline must never be trimmed away.
    func continuation(from text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        if !joiningSeparator.isEmpty {
            return text.first?.isWhitespace == true ? text : joiningSeparator + text
        }
        if targetSnapshot.precedingText.last == " " {
            return String(text.drop(while: { $0 == " " }))
        }
        return text
    }

    private static func isEligible(_ snapshot: FocusedInputSnapshot) -> Bool {
        !snapshot.isSecure && snapshot.selection.length == 0
    }

    private static func matches(_ snapshot: FocusedInputSnapshot, expected: FocusedInputSnapshot) -> Bool {
        sameFocusedField(snapshot, expected)
            && snapshot.contentSignature == expected.contentSignature
    }

    static func sameFocusedField(_ snapshot: FocusedInputSnapshot, _ expected: FocusedInputSnapshot) -> Bool {
        sameFocusedField(snapshot, context: FocusedInputContext(snapshot: expected, generation: 0))
    }

    /// Chromium can replace the AX wrapper without moving focus. FocusTracker already represents
    /// that stable field with a focus sequence and rounded frame, so requiring the wrapper's CFHash
    /// as well would throw away useful prefetch on an ordinary AX refresh. Restrict that tolerance
    /// to web fields with the same real focus sequence and frame; native fields, missing geometry,
    /// and legacy snapshots without a sequence continue to require the exact element identifier.
    static func sameFocusedField(_ snapshot: FocusedInputSnapshot, context expected: FocusedInputContext) -> Bool {
        guard snapshot.sessionIdentity == expected.sessionIdentity,
              snapshot.role == expected.role, snapshot.subrole == expected.subrole else { return false }
        if snapshot.elementIdentifier == expected.elementIdentifier { return true }
        guard snapshot.isWebContentField, expected.isWebContentField,
              snapshot.focusChangeSequence > 0,
              let frame = snapshot.inputFrameRect, let expectedFrame = expected.inputFrameRect else { return false }
        return frame.minX.rounded() == expectedFrame.minX.rounded()
            && frame.minY.rounded() == expectedFrame.minY.rounded()
            && frame.width.rounded() == expectedFrame.width.rounded()
            && frame.height.rounded() == expectedFrame.height.rounded()
    }
}
