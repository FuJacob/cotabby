import Foundation
import Testing
@testable import Cotabby

/// Checks the compiled bundle rather than only the catalog JSON. This catches a catalog omitted
/// from the target, a wrong table name, or plural format arguments that fail at runtime after a
/// structurally valid translator import. No inference or production service startup is needed.
@MainActor
struct LocalizationResourceTests {
    static let translatedLanguages = [
        "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt-BR",
        "it", "ru", "ar", "hi", "id", "tr"
    ]

    @Test(arguments: translatedLanguages)
    func compiledInterfaceResourcesResolve(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let locale = Locale(identifier: language)
        let description = String(
            localized: "Turn Cotabby off everywhere without quitting the app.",
            bundle: bundle, locale: locale
        )
        #expect(!description.isEmpty)
        #expect(description != "Turn Cotabby off everywhere without quitting the app.")

        let example = String(localized: "Thanks for the¦ quick reply!", bundle: bundle, locale: locale)
        #expect(example.components(separatedBy: "¦").count == 2)
        #expect(example != "Thanks for the¦ quick reply!")

        for count in [0, 1, 2, 5, 21] {
            let rendered = String(localized: "\(count) entries stored", bundle: bundle, locale: locale)
            #expect(!rendered.isEmpty)
            #expect(!rendered.contains("%"))
            #expect(rendered != "\(count) entries stored")
        }

        let percent = 7
        let speed = "speed-token"
        let eta = "eta-token"
        let status = String(
            localized: "Downloading \(percent)% (\(speed) · ETA \(eta))",
            bundle: bundle, locale: locale
        )
        #expect(status.contains(speed))
        #expect(status.contains(eta))
        #expect(status.contains("%"))
        #expect(!status.contains("%@"))
        #expect(!status.contains("%lld"))
    }
    @Test
    func generationInstructionStaysEnglishWhenTheTestHostUsesAnotherAppLanguage() {
        let range = SuggestionWordRange(lowWords: 4, highWords: 7)
        #expect(range.promptInstruction == "Return only the next 4 to 7 words.")
    }

}
