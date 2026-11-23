import XCTest
@testable import Cotabby

/// Tests for the single picker value that folds the settings model's two length fields (custom
/// flag plus curated preset) together, and for writing a choice back through the model's setters.
@MainActor
final class SuggestionLengthChoiceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "cotabby.test.lengthChoice.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeModel() -> SuggestionSettingsModel {
        SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
    }

    func test_lengthChoice_reflectsThePresetUntilCustomIsOn() {
        let model = makeModel()
        model.setUsingCustomWordCountRange(false)
        model.selectWordCountPreset(.sevenToTwelve)
        XCTAssertEqual(model.lengthChoice, .preset(.sevenToTwelve))

        model.setUsingCustomWordCountRange(true)
        XCTAssertEqual(model.lengthChoice, .custom)
    }

    func test_selectingCustom_keepsThePresetToSnapBackTo() {
        let model = makeModel()
        model.selectLengthChoice(.preset(.twoToFour))

        model.selectLengthChoice(.custom)

        XCTAssertTrue(model.isUsingCustomWordCountRange)
        XCTAssertEqual(model.selectedWordCountPreset, .twoToFour)
    }

    func test_selectingAPreset_leavesCustomModeAndPersistsBothFields() {
        let model = makeModel()
        model.selectLengthChoice(.custom)

        model.selectLengthChoice(.preset(.sevenToTwelve))

        XCTAssertFalse(model.isUsingCustomWordCountRange)
        XCTAssertEqual(model.selectedWordCountPreset, .sevenToTwelve)
        // A fresh model over the same defaults sees the choice, so both setters reached the store.
        XCTAssertEqual(makeModel().lengthChoice, .preset(.sevenToTwelve))
    }
}
