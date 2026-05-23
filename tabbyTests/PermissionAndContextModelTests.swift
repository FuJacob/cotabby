import XCTest
@testable import tabby

final class TabbyPermissionKindTests: XCTestCase {

    func test_allCases_containsExactlyThreePermissions() {
        XCTAssertEqual(TabbyPermissionKind.allCases.count, 3)
    }

    func test_rawValues_matchExpectedPrivacyKeys() {
        XCTAssertEqual(TabbyPermissionKind.accessibility.rawValue, "Privacy_Accessibility")
        XCTAssertEqual(TabbyPermissionKind.inputMonitoring.rawValue, "Privacy_ListenEvent")
        XCTAssertEqual(TabbyPermissionKind.screenRecording.rawValue, "Privacy_ScreenCapture")
    }

    func test_allCases_haveTitles() {
        for kind in TabbyPermissionKind.allCases {
            XCTAssertFalse(kind.title.isEmpty, "\(kind) should have a non-empty title")
        }
        XCTAssertEqual(TabbyPermissionKind.accessibility.title, "Accessibility")
        XCTAssertEqual(TabbyPermissionKind.inputMonitoring.title, "Input Monitoring")
        XCTAssertEqual(TabbyPermissionKind.screenRecording.title, "Screen Recording")
    }

    func test_allCases_haveSystemImageNames() {
        for kind in TabbyPermissionKind.allCases {
            XCTAssertFalse(
                kind.systemImageName.isEmpty,
                "\(kind) should have a non-empty systemImageName"
            )
        }
    }

    func test_allCases_haveOnboardingSubtitles() {
        for kind in TabbyPermissionKind.allCases {
            XCTAssertFalse(
                kind.onboardingSubtitle.isEmpty,
                "\(kind) should have a non-empty onboardingSubtitle"
            )
        }
    }

    func test_settingsURL_usesExpectedDeepLinkFormat() {
        for kind in TabbyPermissionKind.allCases {
            let expected = "x-apple.systempreferences:com.apple.preference.security?\(kind.rawValue)"
            XCTAssertEqual(kind.settingsURL.absoluteString, expected)
        }
    }

    func test_guidanceStyle_isGuidedOverlayForAllCases() {
        for kind in TabbyPermissionKind.allCases {
            XCTAssertEqual(kind.guidanceStyle, .guidedOverlay)
        }
    }

    func test_isRequiredForAutocomplete_isTrueForAllCases() {
        for kind in TabbyPermissionKind.allCases {
            XCTAssertTrue(
                kind.isRequiredForAutocomplete,
                "\(kind) should be required for autocomplete"
            )
        }
    }

    func test_guidanceHint_isNonEmptyForAllCases() {
        for kind in TabbyPermissionKind.allCases {
            XCTAssertFalse(
                kind.guidanceHint.isEmpty,
                "\(kind) should have a non-empty guidanceHint"
            )
        }
    }
}

final class VisualContextModelTests: XCTestCase {

    func test_status_detail_returnsNonEmptyStringForEachCase() {
        let cases: [VisualContextStatus] = [
            .idle, .capturing, .extractingText, .summarizingText, .ready,
            .unavailable("no permission"), .failed("timeout")
        ]
        let details = cases.map(\.detail)
        for detail in details {
            XCTAssertFalse(detail.isEmpty)
        }
        // All distinct
        XCTAssertEqual(Set(details).count, details.count, "Each status case should have a unique detail")
    }

    func test_status_unavailableAndFailed_includeAssociatedReasonInDetail() {
        let reason = "Screen recording denied"
        XCTAssertEqual(VisualContextStatus.unavailable(reason).detail, reason)
        XCTAssertEqual(VisualContextStatus.failed(reason).detail, reason)
    }

    func test_defaultConfiguration_hasExpectedValues() {
        let config = VisualContextConfiguration.default
        XCTAssertEqual(config.snapshotDimension, 500)
        XCTAssertEqual(config.maxImageDimension, 900)
        XCTAssertEqual(config.minRecognizedCharacterCount, 12)
        XCTAssertEqual(config.maxRecognizedCharacters, 2000)
        XCTAssertEqual(config.maxSummaryCharacters, 900)
    }

    func test_focusedInputAugmentationSession_equatableConformance() {
        let id = UUID()
        let sessionA = FocusedInputAugmentationSession(
            sessionID: id,
            elementIdentifier: "field1",
            focusChangeSequence: 1,
            status: .idle,
            excerpt: nil
        )
        var sessionB = FocusedInputAugmentationSession(
            sessionID: id,
            elementIdentifier: "field1",
            focusChangeSequence: 1,
            status: .idle,
            excerpt: nil
        )
        XCTAssertEqual(sessionA, sessionB)

        sessionB.status = .ready
        XCTAssertNotEqual(sessionA, sessionB)
    }
}
