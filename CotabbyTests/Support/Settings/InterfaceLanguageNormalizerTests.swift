import Testing
@testable import Cotabby

/// Keeps locale handling deterministic and protects unknown startup values from accidental
/// canonicalization into a different user's preference.
struct InterfaceLanguageNormalizerTests {
    @Test
    func normalizesSupportedRegionVariantsAndPreservesUnknownLocales() {
        let cases: [(String, InterfaceLanguageSelection)] = [
            ("en_US", .language(.english)),
            ("zh_CN", .language(.simplifiedChinese)),
            ("zh-HK", .language(.traditionalChinese)),
            ("zh-Hant-CN", .language(.traditionalChinese)),
            ("zh-Hans-TW", .language(.simplifiedChinese)),
            ("ja-JP", .language(.japanese)),
            ("fr-CA", .language(.french)),
            ("pt_BR", .language(.brazilianPortuguese)),
            ("pt-PT", .preservedUnsupported("pt-PT")),
            ("xx-ZZ", .preservedUnsupported("xx-ZZ"))
        ]

        for (identifier, expected) in cases {
            #expect(
                InterfaceLanguageNormalizer.selection(forStoredIdentifier: identifier) == expected,
                "Unexpected normalized selection for \(identifier)"
            )
        }
    }
}
