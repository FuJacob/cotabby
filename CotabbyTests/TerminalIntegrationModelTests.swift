import CoreGraphics
import Darwin
import XCTest
@testable import Cotabby

/// Pure-contract tests for terminal state, prompting, geometry, and Claude Code classification.
/// Socket lifecycle and ScreenCaptureKit remain service integration concerns; these tests lock the
/// deterministic rules that protect Unicode offsets, source identity, and fail-closed OCR.
@MainActor
final class TerminalIntegrationModelTests: XCTestCase {
    func test_bashCursorOffsetNormalizesUTF8BytesToCharacters() {
        XCTAssertEqual(
            TerminalFocusSnapshot.normalizedCharacterOffset(
                rawOffset: "echo 🐱".utf8.count,
                text: "echo 🐱",
                shell: .bash
            ),
            "echo 🐱".count
        )
        XCTAssertEqual(
            TerminalFocusSnapshot.normalizedCharacterOffset(
                rawOffset: 6,
                text: "écho",
                shell: .bash
            ),
            4
        )
    }

    func test_optimisticInsertionPreservesTrailingBufferAndAdvancesRevision() {
        let original = shellSnapshot(text: "git st --short", cursor: 6, revision: 7)

        let updated = original.appendingInsertedText("atus")

        XCTAssertEqual(updated.commandBuffer, "git status --short")
        XCTAssertEqual(updated.cursorCharacterOffset, 10)
        XCTAssertEqual(updated.sourceRevision, 8)
    }

    func test_optimisticReplacementReplacesWholeBufferWithoutExecuting() {
        let original = shellSnapshot(text: "delete folder named dork", cursor: 24, revision: 7)

        let updated = original.replacingCommandBuffer(with: "rm -rf -- dork")

        XCTAssertEqual(updated.commandBuffer, "rm -rf -- dork")
        XCTAssertEqual(updated.cursorCharacterOffset, 14)
        XCTAssertEqual(updated.sourceRevision, 8)
    }

    func test_commandIntentPolicyRecognizesEnglishButNotShellSyntax() {
        XCTAssertTrue(TerminalCommandIntentPolicy.isReplacementIntent("delete folder named dork"))
        XCTAssertTrue(TerminalCommandIntentPolicy.isReplacementIntent("list hidden files"))
        XCTAssertFalse(TerminalCommandIntentPolicy.isReplacementIntent("git status"))
        XCTAssertFalse(TerminalCommandIntentPolicy.isReplacementIntent("rm -rf -- dork"))
        XCTAssertFalse(TerminalCommandIntentPolicy.isReplacementIntent("list files | sort"))
    }

    func test_requestFactoryBuildsWholeCommandReplacementAndNormalizerStripsFence() {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(
            applicationName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            elementIdentifier: "terminal-shell-42-session",
            role: TerminalInputRole.shell.rawValue,
            subrole: ShellType.zsh.rawValue,
            precedingText: "delete folder named dork"
        )
        let context = FocusedInputContext(snapshot: snapshot, generation: 7)

        let build = SuggestionRequestFactory.buildRequest(
            context: context,
            settings: CotabbyTestFixtures.settingsSnapshot(suggestInIntegratedTerminals: true),
            configuration: .standard
        )

        XCTAssertEqual(
            build.request.mode,
            .terminalCommandReplacement(originalText: "delete folder named dork")
        )
        XCTAssertGreaterThanOrEqual(build.request.maxPredictionTokens, 32)
        XCTAssertTrue(build.request.prompt.hasSuffix("Instruction: delete folder named dork\nCommand:"))
        XCTAssertEqual(
            SuggestionTextNormalizer.normalize("```sh\nrm -rf -- dork\n```", for: build.request),
            "rm -rf -- dork"
        )
    }

    func test_productPathsKeepDevelopmentSocketSeparate() {
        let root = URL(fileURLWithPath: "/tmp/cotabby-tests", isDirectory: true)
        let production = TerminalIntegrationPaths(
            bundleIdentifier: "com.jacobfu.tabby",
            applicationSupportRoot: root,
            socketRoot: root
        )
        let development = TerminalIntegrationPaths(
            bundleIdentifier: "com.jacobfu.tabby.dev",
            applicationSupportRoot: root,
            socketRoot: root
        )

        XCTAssertNotEqual(production.socketURL, development.socketURL)
        XCTAssertTrue(development.socketURL.lastPathComponent.contains("dev"))
        XCTAssertLessThan(development.socketURL.path.utf8.count + 1, 104)
    }

    func test_resourceInstallerCopiesHooksWithPrivatePermissions() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cotabby-terminal-installer-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let bundled = temporaryRoot.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        for shell in [ShellType.zsh, .bash, .fish] {
            try Data("hook-\(shell.rawValue)".utf8).write(
                to: bundled.appendingPathComponent("cotabby.\(shell.rawValue)")
            )
        }
        let paths = TerminalIntegrationPaths(
            bundleIdentifier: "com.example.cotabby.tests",
            applicationSupportRoot: temporaryRoot,
            socketRoot: temporaryRoot
        )
        let installer = TerminalIntegrationResourceInstaller(
            paths: paths,
            bundledHooksDirectory: bundled
        )

        try installer.install()

        var rootInfo = stat()
        XCTAssertEqual(lstat(paths.rootDirectory.path, &rootInfo), 0)
        XCTAssertEqual(rootInfo.st_mode & 0o777, 0o700)
        for shell in [ShellType.zsh, .bash, .fish] {
            let destination = paths.hookURL(for: shell)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hook-\(shell.rawValue)")
            var info = stat()
            XCTAssertEqual(lstat(destination.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o600)
        }
    }

    func test_socketServerCreatesPrivateEndpointAndRemovesItOnStop() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ct-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let socketURL = temporaryRoot.appendingPathComponent("terminal.sock")
        let server = TerminalSocketServer(socketURL: socketURL) { _ in }

        try server.start()

        var rootInfo = stat()
        var socketInfo = stat()
        XCTAssertEqual(lstat(temporaryRoot.path, &rootInfo), 0)
        XCTAssertEqual(rootInfo.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(socketURL.path, &socketInfo), 0)
        XCTAssertEqual(socketInfo.st_mode & 0o777, 0o600)
        XCTAssertEqual(socketInfo.st_mode & S_IFMT, S_IFSOCK)

        server.stop()
        XCTAssertNotEqual(lstat(socketURL.path, &socketInfo), 0)
        XCTAssertEqual(errno, ENOENT)
    }

    func test_shellPromptPreservesExactPrefixAsFinalBytes() {
        let prompt = TerminalCompletionPromptRenderer.prompt(
            prefixText: "git commit -m 'fix spacing  ",
            role: .shell,
            shellName: "zsh",
            workingDirectory: "/Users/test/project"
        )

        XCTAssertTrue(prompt.contains("Working directory: Users/test/project"))
        XCTAssertTrue(prompt.hasSuffix("$ git commit -m 'fix spacing  "))
    }

    func test_promptAnchorMatchesBottomMostCommandAndTracksCursor() throws {
        let snapshot = shellSnapshot(text: "git st", cursor: 6)
        let lines = [
            RecognizedTextLine(
                text: "$ git st",
                confidence: 0.9,
                boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.08, height: 0.03)
            ),
            RecognizedTextLine(
                text: "$ git st",
                confidence: 0.95,
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.08, height: 0.03)
            )
        ]
        let region = CGRect(x: 0, y: 0, width: 800, height: 600)
        let anchor = try XCTUnwrap(
            TerminalPromptAnchorResolver.makeAnchor(
                snapshot: snapshot,
                lines: lines,
                captureRegion: region,
                windowFrame: region
            )
        )

        XCTAssertEqual(anchor.promptLineRect.minY, 522, accuracy: 0.001)
        let geometry = TerminalPromptAnchorResolver.geometry(cursorOffset: 6, anchor: anchor)
        XCTAssertGreaterThan(geometry.caret.minX, anchor.promptLineRect.minX)
        XCTAssertEqual(geometry.input.width, region.width)
    }

    func test_tuiDetectorUsesTitleThenProcessAndRejectsNonTerminalApps() {
        XCTAssertEqual(
            TuiSessionDetector.classification(
                bundleIdentifier: "com.apple.Terminal",
                terminalAccessibilityTitle: "project — Claude Code",
                foregroundProcessNames: { XCTFail("Title should short-circuit process lookup"); return [] }
            ),
            .claudeCode
        )
        XCTAssertEqual(
            TuiSessionDetector.classification(
                bundleIdentifier: "com.mitchellh.ghostty",
                terminalAccessibilityTitle: "project",
                foregroundProcessNames: { ["zsh", "claude"] }
            ),
            .claudeCode
        )
        XCTAssertEqual(
            TuiSessionDetector.classification(
                bundleIdentifier: "com.apple.Safari",
                terminalAccessibilityTitle: "Claude Code",
                foregroundProcessNames: { ["claude"] }
            ),
            .notClaudeCode
        )
    }

    func test_tuiDetectorFallsBackToOCRWhenTerminalProcessTreeIsInconclusive() {
        XCTAssertEqual(
            TuiSessionDetector.classification(
                bundleIdentifier: "com.apple.Terminal",
                terminalAccessibilityTitle: "project",
                foregroundProcessNames: { ["Terminal", "login", "zsh"] }
            ),
            .unknown
        )
    }

    func test_tuiReaderRequiresWindowFingerprintAndSelectsBottomMostPrompt() async throws {
        let extraction = ExtractedScreenText(
            text: "Claude Code\n❯ menu item\n❯ explain this test\nshift+tab",
            lineCount: 4,
            positionedLines: [
                .init(text: "Claude Code", confidence: 1, boundingBox: .init(x: 0, y: 0.8, width: 0.2, height: 0.05)),
                .init(text: "❯ menu item", confidence: 1, boundingBox: .init(x: 0, y: 0.5, width: 0.2, height: 0.05)),
                .init(text: "❯ explain this test", confidence: 1, boundingBox: .init(x: 0, y: 0.2, width: 0.3, height: 0.05)),
                .init(text: "shift+tab", confidence: 1, boundingBox: .init(x: 0, y: 0.1, width: 0.2, height: 0.05))
            ]
        )
        let reader = TuiContextReader(extractor: StubScreenTextExtractor(result: extraction))

        let reading = try await reader.read(image: makeImage())

        XCTAssertTrue(reading.looksLikeClaudeCode)
        XCTAssertEqual(reading.promptText, "explain this test")
        XCTAssertEqual(reading.estimatedCursorOffset, 17)
    }

    private func shellSnapshot(
        text: String,
        cursor: Int,
        revision: UInt64 = 1
    ) -> TerminalFocusSnapshot {
        TerminalFocusSnapshot(
            sessionIdentity: TerminalSessionIdentity(shellPid: 42, nonce: "session"),
            commandBuffer: text,
            cursorCharacterOffset: cursor,
            shellType: .zsh,
            terminalBundleIdentifier: "com.apple.Terminal",
            tty: "/dev/ttys001",
            workingDirectory: "/Users/test/project",
            sourceRevision: revision
        )
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 4,
                height: 4,
                bitsPerComponent: 8,
                bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try XCTUnwrap(context.makeImage())
    }
}

private struct StubScreenTextExtractor: ScreenTextExtracting {
    let result: ExtractedScreenText

    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        result
    }
}
