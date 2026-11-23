import SwiftUI

extension SuggestionSettingsModel {
    /// A two-way binding for a control that edits one preference. Reads come straight from the
    /// published property and writes go through its setter, so a control can never bypass the
    /// normalization and persistence the setter owns. Lives in the UI layer so the model itself
    /// stays free of SwiftUI.
    func binding<Value>(
        _ keyPath: KeyPath<SuggestionSettingsModel, Value>,
        set: @escaping (SuggestionSettingsModel, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { set(self, $0) }
        )
    }
}
