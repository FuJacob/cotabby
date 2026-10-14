import XCTest
@testable import Cotabby

/// The rewrite names the draft's language because Apple's model otherwise can drift into English on
/// a draft that mixes in English words. Detection is limited to the languages the user writes in,
/// because unconstrained recognition can misname a short draft typed without accents.
final class RewriteLanguageDetectorTests: XCTestCase {
    private let languages = ["English", "Turkish"]

    func test_turkishDraftWithEnglishWordsIsTurkish() {
        XCTAssertEqual(RewriteLanguageDetector.language(of: "bu aksam party var, sen de gel lutfen", among: languages), "Turkish")
    }

    func test_englishDraftIsEnglish() {
        XCTAssertEqual(RewriteLanguageDetector.language(of: "Please let me know if te dates are ok and wors for you.", among: languages), "English")
    }

    func test_freeTextLanguageNamesAreUnderstood() {
        // "Turkish" is not in the built-in palette; the system's English language names resolve it.
        XCTAssertEqual(RewriteLanguageDetector.code(forLanguageName: "Turkish"), "tr")
        XCTAssertEqual(RewriteLanguageDetector.code(forLanguageName: "german"), "de")
        XCTAssertNil(RewriteLanguageDetector.code(forLanguageName: "Klingonish"))
    }

    func test_languageOutsideTheUsersSetIsNotNamed() {
        // Only English declared: a German draft is not forced to "English", and not guessed either.
        XCTAssertNil(RewriteLanguageDetector.language(of: "Können wir uns morgen um zehn Uhr treffen?", among: ["English"]))
    }

    func test_withoutDeclaredLanguagesAConfidentGuessIsNamed() {
        XCTAssertEqual(RewriteLanguageDetector.language(of: "Können wir uns morgen um zehn Uhr im Büro treffen?", among: []), "German")
    }
}
