import Foundation

/// Maps between the stored fade-in duration and the position of the Slow-to-Fast speed slider.
///
/// The preference is a duration, but the control reads as a speed, and the two run in opposite
/// directions: a faster fade is a shorter duration. Reflecting across the midpoint of the allowed
/// duration band turns one into the other while keeping the slider's ticks on the stored steps,
/// so the shared tick-mark slider (which assumes an increasing value) needs no special casing.
enum FadeSpeedAxis {
    /// Reflects a duration to its slider position, or a slider position back to its duration.
    /// Applying it twice is the identity, which is what keeps a binding's get and set in sync.
    static func reflected(_ value: Double) -> Double {
        (SuggestionSettingsStore.minimumFadeInDuration + SuggestionSettingsStore.maximumFadeInDuration) - value
    }
}
