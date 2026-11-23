import XCTest
@testable import Cotabby

/// The fade speed slider shows a duration preference on a reversed axis. These pin the two
/// properties the Appearance pane's binding relies on: the ends swap, and the map undoes itself.
final class FadeSpeedAxisTests: XCTestCase {
    func test_slowestDurationSitsAtTheSlowEndAndFastestAtTheFastEnd() {
        let slowest = SuggestionSettingsStore.maximumFadeInDuration
        let fastest = SuggestionSettingsStore.minimumFadeInDuration

        XCTAssertEqual(FadeSpeedAxis.reflected(slowest), fastest, accuracy: 1e-9)
        XCTAssertEqual(FadeSpeedAxis.reflected(fastest), slowest, accuracy: 1e-9)
    }

    func test_reflectingTwiceReturnsTheStoredDuration() {
        var duration = SuggestionSettingsStore.minimumFadeInDuration
        while duration <= SuggestionSettingsStore.maximumFadeInDuration + 1e-9 {
            XCTAssertEqual(FadeSpeedAxis.reflected(FadeSpeedAxis.reflected(duration)), duration, accuracy: 1e-9)
            duration += SuggestionSettingsStore.fadeInDurationStep
        }
    }

    func test_everySliderTickLandsOnAStoredStep() {
        let minimum = SuggestionSettingsStore.minimumFadeInDuration
        let step = SuggestionSettingsStore.fadeInDurationStep
        var duration = minimum
        while duration <= SuggestionSettingsStore.maximumFadeInDuration + 1e-9 {
            let stepsFromMinimum = (FadeSpeedAxis.reflected(duration) - minimum) / step
            XCTAssertEqual(stepsFromMinimum, stepsFromMinimum.rounded(), accuracy: 1e-6)
            duration += step
        }
    }
}
