import XCTest
@testable import Cotabby

/// Structural checks on the curated ghost-text palette in `GhostTextColorPreset`. The `matching`
/// lookups themselves are covered by `GhostTextColorPresetTests`; these pin the invariants the
/// Settings swatch grid relies on: Automatic leads, every swatch is distinct, and every stored hex
/// round-trips back to its own swatch so the active selection highlights correctly.
final class GhostTextColorPresetPaletteTests: XCTestCase {
    func test_all_leadsWithAutomaticFollowedByTenDistinctAccents() {
        XCTAssertEqual(GhostTextColorPreset.all.first, .automatic)
        XCTAssertEqual(GhostTextColorPreset.all.count, 11)
        XCTAssertEqual(Set(GhostTextColorPreset.all.map(\.id)).count, 11, "swatch ids must be unique")
        XCTAssertEqual(Set(GhostTextColorPreset.all.compactMap(\.hex)).count, 10, "accent hexes must be unique")
        XCTAssertEqual(GhostTextColorPreset.all.filter { $0.hex == nil }, [.automatic])
    }

    func test_all_accentHexesUseThePersistedUppercaseSixDigitFormat() {
        let hexDigits = CharacterSet(charactersIn: "0123456789ABCDEF")
        for preset in GhostTextColorPreset.all {
            guard let hex = preset.hex else { continue }
            XCTAssertEqual(hex.count, 6, preset.id)
            XCTAssertTrue(hex.unicodeScalars.allSatisfy(hexDigits.contains(_:)), preset.id)
        }
    }

    func test_matching_roundTripsEveryPresetAndTreatsBlankAsAutomatic() {
        for preset in GhostTextColorPreset.all {
            XCTAssertEqual(GhostTextColorPreset.matching(hex: preset.hex), preset, preset.id)
        }
        XCTAssertEqual(GhostTextColorPreset.matching(hex: ""), .automatic)
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "   "), .automatic)
    }
}
