import Foundation

/// File overview:
/// The single value a "suggestion length" picker selects. The settings model stores length as two
/// fields (`isUsingCustomWordCountRange` plus the curated `selectedWordCountPreset`, which is kept
/// while Custom is on so turning Custom off snaps back to it). A picker needs one tag per row, so
/// this folds the pair into one choice and writes it back through the model's own setters.
enum SuggestionLengthChoice: Hashable {
    case preset(SuggestionWordCountPreset)
    case custom
}

extension SuggestionSettingsModel {
    var lengthChoice: SuggestionLengthChoice {
        isUsingCustomWordCountRange ? .custom : .preset(selectedWordCountPreset)
    }

    /// Choosing Custom leaves the stored preset untouched on purpose (see the file overview).
    func selectLengthChoice(_ choice: SuggestionLengthChoice) {
        switch choice {
        case let .preset(preset):
            setUsingCustomWordCountRange(false)
            selectWordCountPreset(preset)
        case .custom:
            setUsingCustomWordCountRange(true)
        }
    }
}
