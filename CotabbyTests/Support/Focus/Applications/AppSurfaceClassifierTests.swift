import XCTest
@testable import Cotabby

/// Pins the shared bundle-to-surface classification both prompt renderers depend on, including the
/// precedence rules (integrated terminal beats everything; code editor beats the Electron/browser
/// overlap for VS Code).
final class AppSurfaceClassifierTests: XCTestCase {
    func test_classifiesEachCuratedFamily() {
        let cases: [(bundleIdentifier: String, expected: AppSurfaceClass)] = [
            ("com.apple.Terminal", .terminal),
            ("com.googlecode.iterm2", .terminal),
            ("com.apple.dt.Xcode", .codeEditor),
            ("com.jetbrains.intellij", .codeEditor),
            ("com.sublimetext.4", .codeEditor),
            ("com.panic.Nova", .codeEditor),
            ("com.apple.mail", .email),
            ("com.microsoft.Outlook", .email),
            ("com.readdle.smartemail-Mac", .email),
            ("com.tinyspeck.slackmacgap", .chat),
            ("com.hnc.Discord", .chat),
            ("com.apple.MobileSMS", .chat),
            ("ru.keepcoder.Telegram", .chat),
            ("net.whatsapp.WhatsApp", .chat),
            ("com.microsoft.teams2", .chat),
            ("com.apple.Safari", .browser),
            ("com.google.Chrome", .browser),
            ("org.mozilla.firefox", .browser),
            ("company.thebrowser.Browser", .browser),
            ("com.microsoft.edgemac", .browser)
        ]
        for (bundleIdentifier, expected) in cases {
            XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: bundleIdentifier), expected, bundleIdentifier)
        }
    }

    func test_integratedTerminalBeatsEverything() {
        XCTAssertEqual(
            AppSurfaceClassifier.classify(bundleIdentifier: "com.google.Chrome", isIntegratedTerminal: true),
            .terminal
        )
        // The xterm.js signal needs no host bundle at all.
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: nil, isIntegratedTerminal: true), .terminal)
    }

    func test_vsCodeFamilyClassifiesAsCodeEditorNotBrowser() {
        // VS Code is also in the Electron-editor browser-priming set; code editor must win. Insiders
        // shares the `com.microsoft.vscode` prefix.
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.microsoft.VSCode"), .codeEditor)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.microsoft.VSCodeInsiders"), .codeEditor)
    }

    func test_prefixTablesAreCaseInsensitive() {
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "COM.APPLE.MAIL"), .email)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "COM.GOOGLE.CHROME"), .browser)
    }

    func test_prefixTablesAreLowercase() {
        // Classification lowercases the bundle id before prefix matching, so a mixed-case table
        // entry would silently never match.
        let prefixes = AppSurfaceClassifier.codeEditorBundlePrefixes
            + AppSurfaceClassifier.emailBundlePrefixes
            + AppSurfaceClassifier.chatBundlePrefixes
        for prefix in prefixes {
            XCTAssertEqual(prefix, prefix.lowercased(), prefix)
        }
    }

    func test_unknownAndNil() {
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.example.unknown"), .other)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: nil), .other)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: ""), .other)
    }
}
