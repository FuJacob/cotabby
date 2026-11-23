import XCTest
@testable import Cotabby

/// Checks on the curated ghost-text palette in `GhostTextColorPreset`: the invariants the Settings
/// swatch grid relies on (Automatic leads, every swatch is distinct, every stored hex decodes) and
/// the `matching` lookup that maps a stored hex back to its swatch so the active selection
/// highlights correctly.
final class GhostTextColorPresetTests: XCTestCase {
    func test_all_leadsWithAutomaticFollowedByDistinctColors() {
        let all = GhostTextColorPreset.all
        XCTAssertEqual(all.first, .automatic)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "swatch ids must be unique")
        XCTAssertEqual(Set(all.compactMap(\.hex)).count, all.count - 1, "accent hexes must be unique")
        XCTAssertEqual(all.filter { $0.hex == nil }, [.automatic])
    }

    /// White is offered for dark editors, as the last swatch so the hue run stays together.
    func test_all_endsWithWhite() {
        XCTAssertEqual(GhostTextColorPreset.all.last?.id, "white")
        XCTAssertEqual(GhostTextColorPreset.all.last?.hex, "FFFFFF")
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

    func test_matching_nilHexResolvesToAutomatic() {
        XCTAssertEqual(GhostTextColorPreset.matching(hex: nil), .automatic)
    }

    func test_matching_isCaseInsensitiveAndIgnoresWhitespace() {
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "  3b82f6 ").id, "blue")
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "EC4899").id, "pink")
    }

    func test_matching_unknownHexFallsBackToAutomatic() {
        XCTAssertEqual(GhostTextColorPreset.matching(hex: "010203"), .automatic)
    }

    func test_allPresetHexesAreValidAndDecodable() {
        for preset in GhostTextColorPreset.all where preset.hex != nil {
            XCTAssertNotNil(
                SuggestionTextColorCodec.nsColor(fromHex: preset.hex),
                "Preset \(preset.id) has an undecodable hex"
            )
        }
    }
}
