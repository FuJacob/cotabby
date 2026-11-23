import Foundation

/// The one rule for choosing which installed model is selected: keep the highest-priority
/// candidate that is still on disk, otherwise fall back to the first discovered model.
///
/// The persisted selection, the in-memory selection, and the runtime manager's own copy all go
/// through this rule so a model that was deleted or renamed can never stay selected in one layer
/// while another layer has already moved on.
enum RuntimeModelSelection {
    /// `candidates` are tried in order; `nil` entries (no stored choice) are skipped. Returns nil
    /// only when nothing is installed.
    static func resolve(candidates: [String?], available: [RuntimeModelOption]) -> String? {
        for case let candidate? in candidates where available.contains(where: { $0.filename == candidate }) {
            return candidate
        }
        return available.first?.filename
    }
}
