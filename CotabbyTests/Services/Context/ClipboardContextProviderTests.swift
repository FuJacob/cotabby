import AppKit
import XCTest
@testable import Cotabby

/// Tests for the on-demand clipboard description used as optional prompt context.
///
/// Every case writes to a uniquely named private pasteboard, never `NSPasteboard.general`, so the
/// user's real clipboard is untouched. What is pinned: text wins and is trimmed, blank text is not
/// context, and images are summarized by format and pixel size rather than passed through.
@MainActor
final class ClipboardContextProviderTests: XCTestCase {
    /// Providers are `@MainActor` objects; retaining them sidesteps the app-hosted isolated-deinit
    /// crash other suites work around the same way.
    private static var retainedProviders: [ClipboardContextProvider] = []

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.cotabby.tests.clipboard.\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func makeProvider() -> ClipboardContextProvider {
        let provider = ClipboardContextProvider(pasteboard: pasteboard)
        Self.retainedProviders.append(provider)
        return provider
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func test_emptyPasteboardHasNoContext() {
        XCTAssertNil(makeProvider().currentContext())
    }

    func test_textIsTrimmed() {
        pasteboard.setString("  \n Quarterly budget draft \n\t", forType: .string)

        XCTAssertEqual(makeProvider().currentContext(), "Quarterly budget draft")
    }

    func test_whitespaceOnlyTextIsNotContext() {
        pasteboard.setString(" \n\t ", forType: .string)

        XCTAssertNil(makeProvider().currentContext())
    }

    func test_imageIsSummarizedByFormatAndPixelSize() throws {
        pasteboard.setData(try pngData(width: 4, height: 3), forType: .png)

        XCTAssertEqual(makeProvider().currentContext(), "Image (PNG, 4x3 px)")
    }

    func test_textTakesPrecedenceOverAnImage() throws {
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("caption", forType: .string)
        pasteboard.setData(try pngData(width: 4, height: 3), forType: .png)

        XCTAssertEqual(makeProvider().currentContext(), "caption")
    }

    /// The coordinator compares change counts to notice a new copy without reading contents.
    func test_changeCountTracksThePasteboard() {
        let provider = makeProvider()
        let before = provider.currentChangeCount

        pasteboard.clearContents()
        pasteboard.setString("new copy", forType: .string)

        XCTAssertEqual(provider.currentChangeCount, pasteboard.changeCount)
        XCTAssertGreaterThan(provider.currentChangeCount, before)
    }
}
