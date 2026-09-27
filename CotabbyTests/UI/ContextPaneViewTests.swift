import XCTest
@testable import Cotabby

/// Guards the live preview's privacy copy. The preview runs the production suggestion pipeline, so
/// whatever it promises about where typed text goes has to match the engine that will receive it.
@MainActor
final class ContextPaneViewTests: XCTestCase {
    func testOnDeviceEnginesPromiseTheTextStaysOnTheMac() {
        for engine in [SuggestionEngineKind.appleIntelligence, .llamaOpenSource] {
            let note = ContextPaneView.livePreviewPrivacyNote(for: engine)
            XCTAssertTrue(note.contains("on-device"), "\(engine): \(note)")
            XCTAssertFalse(note.contains("endpoint"), "\(engine): \(note)")
        }
    }

    func testEndpointDisclosesThatTypedTextIsSent() {
        let note = ContextPaneView.livePreviewPrivacyNote(for: .openAICompatible)
        XCTAssertTrue(note.contains("sent to your configured endpoint"), note)
        XCTAssertFalse(note.contains("on-device"), "A remote endpoint is not an on-device model: \(note)")
        XCTAssertFalse(note.contains("shared;"), "The endpoint note must not claim nothing is shared: \(note)")
    }
}
