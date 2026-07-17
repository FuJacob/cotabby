import XCTest
@testable import Cotabby

/// Pins the shared bundle-to-surface classification both prompt renderers depend on, including the
/// precedence rules (integrated terminal beats everything; code editor beats the Electron/browser
/// overlap for VS Code).
final class AppSurfaceClassifierTests: XCTestCase {
    func testIntegratedTerminalBeatsEverything() {
        XCTAssertEqual(
            AppSurfaceClassifier.classify(bundleIdentifier: "com.google.Chrome", isIntegratedTerminal: true),
            .terminal
        )
    }

    func testTerminalApps() {
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.apple.Terminal"), .terminal)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.googlecode.iterm2"), .terminal)
    }

    func testCodeEditors() {
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.apple.dt.Xcode"), .codeEditor)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.jetbrains.intellij"), .codeEditor)
    }

    func testVSCodeClassifiesAsCodeEditorNotBrowser() {
        // VS Code is also in the Electron-editor browser-priming set; code editor must win.
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.microsoft.VSCode"), .codeEditor)
    }

    func testEmailClients() {
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.apple.mail"), .email)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.microsoft.Outlook"), .email)
    }

    func testChatApps() {
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.hnc.Discord"), .chat)
    }

    func testBrowsers() {
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.apple.Safari"), .browser)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.google.Chrome"), .browser)
    }

    func testUnknownAndNil() {
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: "com.example.unknown"), .other)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: nil), .other)
        XCTAssertEqual(AppSurfaceClassifier.classify(bundleIdentifier: ""), .other)
    }
}
