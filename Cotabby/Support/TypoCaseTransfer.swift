import Foundation

/// File overview:
/// Pure helper that copies a typo's capitalization onto its correction. `NSSpellChecker` returns
/// dictionary-cased guesses (`the`, not `The`), so without this a leading-capital typo like `Teh`
/// would be "fixed" to a lowercase `the`, which reads as broken. Kept tiny and pure for testability.
enum TypoCaseTransfer {
    /// Returns `correction` recased to match the casing pattern of `source`:
    ///  - source is all uppercase (more than one letter) -> uppercased correction (`HTE` -> `THE`),
    ///  - source starts with a capital -> capitalize the correction's first letter (`Teh` -> `The`),
    ///  - otherwise the correction is returned unchanged (lowercase dictionary form).
    static func applying(caseOf source: String, to correction: String) -> String {
        guard !correction.isEmpty else { return correction }
        let sourceLetters = source.filter { $0.isLetter }
        guard !sourceLetters.isEmpty else { return correction }

        if sourceLetters.count > 1, sourceLetters.allSatisfy({ $0.isUppercase }) {
            return correction.uppercased()
        }

        if let first = sourceLetters.first, first.isUppercase {
            return correction.prefix(1).uppercased() + correction.dropFirst()
        }

        return correction
    }
}
