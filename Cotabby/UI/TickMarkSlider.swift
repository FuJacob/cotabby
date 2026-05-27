import AppKit
import SwiftUI

/// A macOS slider with evenly spaced, visible tick marks that the knob snaps to.
///
/// SwiftUI's `Slider` can snap to a `step` but cannot draw tick marks on macOS, and the ghost-text
/// opacity control is specced with visible notches. Wrapping `NSSlider` gives native ticks plus
/// `allowsTickMarkValuesOnly` snapping in one control.
struct TickMarkSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.numberOfTickMarks = tickCount
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        // Avoid feeding the slider its own in-flight value back as an external update.
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    /// Inclusive of both endpoints, e.g. 0.3...1.0 at 0.1 yields 8 ticks.
    private var tickCount: Int {
        guard step > 0 else {
            return 2
        }

        let span = range.upperBound - range.lowerBound
        return Int((span / step).rounded()) + 1
    }

    @MainActor
    final class Coordinator: NSObject {
        var value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc
        func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}
