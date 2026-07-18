import Foundation

/// File overview:
/// Scores nearby AX candidates and decides which one, if any, is the best editable target
/// for Cotabby. This keeps heuristic choice separate from raw AX crawling in `FocusTracker`.
///
/// One nearby AX node scored by whether it exposes the capabilities Cotabby needs.
struct FocusCapabilityCandidate: Equatable {
    let elementIdentifier: String
    let role: String
    let subrole: String?
    let editableHintScore: Int
    let hasStrongEditabilitySignal: Bool
    let isKnownReadOnlyRole: Bool
    let hasTextValue: Bool
    let hasSelectionRange: Bool
    let hasCaretBounds: Bool
    let isSecure: Bool
}

/// The derived score and missing-capability breakdown for one candidate element.
struct FocusCapabilityCandidateEvaluation: Equatable {
    let candidate: FocusCapabilityCandidate
    let missingCapabilities: [FocusCapabilityRequirement]
    let score: Int

    var hasFullCapabilities: Bool {
        missingCapabilities.isEmpty
    }
}

/// This is the resolver output, including the best partial candidate for diagnostics.
/// The resolver's final answer about which candidate to trust and why.
struct FocusCapabilityResolution: Equatable {
    let selectedEvaluation: FocusCapabilityCandidateEvaluation?
    let inspectedCandidateCount: Int

    var resolvedCandidate: FocusCapabilityCandidate? {
        guard let selectedEvaluation, selectedEvaluation.hasFullCapabilities else {
            return nil
        }

        return selectedEvaluation.candidate
    }

    var bestDiagnosticCandidate: FocusCapabilityCandidate? {
        selectedEvaluation?.candidate
    }

    var missingCapabilities: [FocusCapabilityRequirement] {
        selectedEvaluation?.missingCapabilities ?? FocusCapabilityRequirement.allCases
    }

    var unsupportedReason: String {
        selectedEvaluation?.missingCapabilities.first?.unsupportedReason
            ?? "No nearby text target exposed the required Accessibility capabilities."
    }
}

/// We rank candidates by capability first and role hints second.
/// This is more robust than assuming the focused node will always be a text field.
enum FocusCapabilityResolver {
    /// Chooses the strongest editable candidate from the nearby AX elements discovered by `FocusTracker`.
    static func resolve(candidates: [FocusCapabilityCandidate]) -> FocusCapabilityResolution {
        var bestPartial: FocusCapabilityCandidateEvaluation?

        for (index, candidate) in candidates.enumerated() {
            let evaluation = evaluate(candidate)

            if evaluation.hasFullCapabilities {
                return FocusCapabilityResolution(
                    selectedEvaluation: evaluation,
                    inspectedCandidateCount: index + 1
                )
            }

            if shouldReplace(bestPartial, with: evaluation) {
                bestPartial = evaluation
            }
        }

        return FocusCapabilityResolution(
            selectedEvaluation: bestPartial,
            inspectedCandidateCount: candidates.count
        )
    }

    /// Computes the capability gaps and heuristic score for a single candidate element.
    static func evaluate(_ candidate: FocusCapabilityCandidate) -> FocusCapabilityCandidateEvaluation {
        let missingCapabilities = FocusCapabilityRequirement.allCases.filter { requirement in
            switch requirement {
            case .textValue:
                return !candidate.hasTextValue
            case .selectionRange:
                return !candidate.hasSelectionRange
            case .caretBounds:
                return !candidate.hasCaretBounds
            case .editableTarget:
                return candidate.isKnownReadOnlyRole || !candidate.hasStrongEditabilitySignal
            }
        }

        let availableCapabilityCount = FocusCapabilityRequirement.allCases.count - missingCapabilities.count
        let score = (availableCapabilityCount * 100) + candidate.editableHintScore

        return FocusCapabilityCandidateEvaluation(
            candidate: candidate,
            missingCapabilities: missingCapabilities,
            score: score
        )
    }

    /// Breaks ties between two scored candidates using editability strength and support completeness.
    private static func shouldReplace(
        _ currentBest: FocusCapabilityCandidateEvaluation?,
        with candidate: FocusCapabilityCandidateEvaluation
    ) -> Bool {
        guard let currentBest else {
            return true
        }

        return candidate.score > currentBest.score
    }
}
