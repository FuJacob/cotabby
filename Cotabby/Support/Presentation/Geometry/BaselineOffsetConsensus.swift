import CoreGraphics

/// File overview:
/// The baseline offset one field agrees on, assembled from the per-line pixel measurements
/// `HostBaselineCalibrator` takes as the caret visits lines.
///
/// Why this exists: the offset from a caret box's top to the painted baseline is a property of the
/// field's font and line box, so every line of a field shares it. The per-line measurements that
/// find it are not equally trustworthy, though. Measured in Obsidian with the alignment harness:
/// line 1 read 16.0 and the ghost sat 0.1pt from the host's text; line 2 read 15.0 and the ghost
/// sat a full point high. Using each line's own reading verbatim is exactly what put ghost text
/// visibly higher on some lines than others.
///
/// Rule: the first accepted reading defines the field. A later reading that agrees (within
/// `agreementTolerance`) confirms it and clears any lone dissent. A reading that disagrees is held
/// as a dissent rather than applied; only when a second reading agrees with that dissent does the
/// field switch to it, and it does so at most once. So a single stray line can never move the
/// text, a stray FIRST line is outvoted by the next two, and the value never drifts sample by
/// sample the way a running median does (which was tried, and moved text that was already placed).
///
/// Pure value type so the rule is unit-tested without a screen; the calibrator owns one per field.
struct BaselineOffsetConsensus: Equatable {
    /// Readings this close to the field value are the same measurement with pixel noise.
    static let agreementTolerance: CGFloat = 0.75
    /// Two dissenting readings this close to each other are treated as agreeing with each other.
    static let dissentAgreementTolerance: CGFloat = 0.5

    private(set) var value: CGFloat
    private(set) var dissent: CGFloat?
    private(set) var hasCorrected = false

    init(first: CGFloat) {
        value = first
    }

    /// Folds one accepted measurement in. Returns true only when the field value changed, which
    /// is the one case a ghost already on screen should move.
    mutating func offer(_ measured: CGFloat) -> Bool {
        if abs(measured - value) <= Self.agreementTolerance {
            dissent = nil
            return false
        }
        if let dissent, !hasCorrected, abs(measured - dissent) <= Self.dissentAgreementTolerance {
            value = measured
            self.dissent = nil
            hasCorrected = true
            return true
        }
        dissent = measured
        return false
    }
}
