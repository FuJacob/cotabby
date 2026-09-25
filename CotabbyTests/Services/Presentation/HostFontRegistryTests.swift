import CoreGraphics
import Security
import XCTest
@testable import Cotabby

/// Tests for the two decisions `HostFontRegistry` makes before a host's bundled font reaches
/// CoreText: *which* face a family name means, and *whether* the host may supply fonts at all.
///
/// Registration itself needs a real host bundle, so it is not exercised here; the trust check is,
/// against this test host's own (unsigned) bundle and, when present, the installed Office apps.
@MainActor
final class HostFontRegistryTests: XCTestCase {
    private func face(
        _ postScriptName: String,
        italic: Bool = false,
        weight: CGFloat = 0,
        width: CGFloat = 0
    ) -> HostFontRegistry.FontFace {
        HostFontRegistry.FontFace(
            postScriptName: postScriptName,
            familyName: "Family",
            isItalic: italic,
            weight: weight,
            width: width
        )
    }

    // MARK: - Family face selection

    /// Word's `DFonts` lists Malgun Gothic's Semilight file before its Regular one. A rule that only
    /// checked the bold and italic bits took the Semilight face, since Semilight carries neither.
    func test_familyResolvesToTheRegularWeightNotTheFirstFileListed() {
        let faces = [
            face("MalgunGothic-Semilight", weight: -0.23),
            face("MalgunGothic", weight: 0),
            face("MalgunGothicBold", weight: 0.4)
        ]
        XCTAssertEqual(HostFontRegistry.familyRepresentative(among: faces)?.postScriptName, "MalgunGothic")
    }

    func test_mediumAndLightDoNotBeatRegular() {
        // Dubai resolved to Dubai-Medium under the old rule.
        let faces = [
            face("Dubai-Medium", weight: 0.2),
            face("Dubai-Light", weight: -0.23),
            face("Dubai-Regular", weight: 0),
            face("Dubai-Bold", weight: 0.4)
        ]
        XCTAssertEqual(HostFontRegistry.familyRepresentative(among: faces)?.postScriptName, "Dubai-Regular")
    }

    func test_uprightBeatsItalicBeforeWeightIsConsidered() {
        let faces = [
            face("Aptos-Light-Italic", italic: true, weight: -0.23),
            face("Aptos-SemiBold", weight: 0.23)
        ]
        XCTAssertEqual(HostFontRegistry.familyRepresentative(among: faces)?.postScriptName, "Aptos-SemiBold")
    }

    func test_condensedLosesToNormalWidth() {
        let faces = [
            face("Rockwell-Condensed", width: -0.2),
            face("Rockwell", width: 0)
        ]
        XCTAssertEqual(HostFontRegistry.familyRepresentative(among: faces)?.postScriptName, "Rockwell")
    }

    func test_italicOnlyFamilyStillResolves() {
        let faces = [face("LucidaCalligraphy-Italic", italic: true)]
        XCTAssertEqual(
            HostFontRegistry.familyRepresentative(among: faces)?.postScriptName,
            "LucidaCalligraphy-Italic"
        )
    }

    func test_selectionDoesNotDependOnListingOrder() {
        let faces = [
            face("MicrosoftYaHeiLight", weight: -0.25),
            face("MicrosoftYaHei", weight: 0),
            face("MicrosoftYaHei-Bold", weight: 0.4),
            face("MicrosoftYaHei-Semibold", weight: 0.3)
        ]
        let choices = Set([faces, faces.reversed(), [faces[2], faces[0], faces[3], faces[1]]].compactMap {
            HostFontRegistry.familyRepresentative(among: $0)?.postScriptName
        })
        XCTAssertEqual(choices, ["MicrosoftYaHei"])
    }

    func test_identicalTraitsBreakTiesByPostScriptName() {
        let faces = [face("Zeta-Regular"), face("Alpha-Regular")]
        XCTAssertEqual(HostFontRegistry.familyRepresentative(among: faces)?.postScriptName, "Alpha-Regular")
    }

    // MARK: - Host trust

    func test_onlyTheAllowlistedOfficeHostsAreTrusted() {
        for bundleIdentifier in [
            "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint",
            "com.microsoft.Outlook", "com.microsoft.onenote.mac"
        ] {
            XCTAssertTrue(HostFontRegistry.isTrustedHost(bundleIdentifier: bundleIdentifier), bundleIdentifier)
        }
        for bundleIdentifier in ["com.google.Chrome", "com.apple.TextEdit", "com.microsoft.word.evil", ""] {
            XCTAssertFalse(HostFontRegistry.isTrustedHost(bundleIdentifier: bundleIdentifier), bundleIdentifier)
        }
    }

    func test_codeRequirementCompilesAndPinsTheIdentifier() {
        let requirementText = HostFontRegistry.hostCodeRequirement(for: "com.microsoft.Word")
        var requirement: SecRequirement?

        XCTAssertEqual(SecRequirementCreateWithString(requirementText as CFString, [], &requirement), errSecSuccess)
        XCTAssertTrue(requirementText.hasPrefix("identifier \"com.microsoft.Word\" and "))
    }

    /// Anything that is not an Apple-anchored Microsoft build — here, this unsigned test host — must
    /// fail, however it is named.
    func test_aBundleThatIsNotMicrosoftSignedFailsTheTrustCheck() {
        XCTAssertFalse(
            HostFontRegistry.bundleSatisfiesHostRequirement(
                at: Bundle.main.bundleURL,
                bundleIdentifier: "com.microsoft.Word"
            )
        )
    }

    func test_installedWordPassesTheTrustCheck() throws {
        let word = URL(fileURLWithPath: "/Applications/Microsoft Word.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: word.path), "Microsoft Word is not installed")

        XCTAssertTrue(HostFontRegistry.bundleSatisfiesHostRequirement(at: word, bundleIdentifier: "com.microsoft.Word"))
    }

    /// The identifier pin: a genuine, validly signed Office app still cannot stand in for another.
    func test_aGenuineOfficeAppCannotStandInForAnother() throws {
        let excel = URL(fileURLWithPath: "/Applications/Microsoft Excel.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: excel.path), "Microsoft Excel is not installed")

        XCTAssertFalse(HostFontRegistry.bundleSatisfiesHostRequirement(at: excel, bundleIdentifier: "com.microsoft.Word"))
    }
}
