import Foundation
import XCTest
@testable import Cotabby

/// Tests the `defaults write` escape hatches for the decode gates against an isolated suite, so
/// the confidence floor and the argmax-EOG stop are provably adjustable in the field without a
/// rebuild (and without touching process-global defaults from the test host).
@MainActor
final class LlamaDecodeGateDefaultsTests: XCTestCase {
    private let suiteName = "LlamaDecodeGateDefaultsTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_confidenceFloor_defaultsToShippedValue() {
        XCTAssertEqual(
            LlamaSuggestionEngine.resolvedConfidenceFloor(defaults),
            LlamaSuggestionEngine.defaultConfidenceFloor
        )
    }

    /// The gate ships OFF: a -1.5 floor withheld ~56% of real completions, so confidence
    /// suppression is opt-in until it is recalibrated against real usage. -infinity also turns off
    /// the per-token logprob computation, so this lock guards both the coverage and the latency.
    func test_confidenceFloor_shippedOff_byDefault() {
        XCTAssertEqual(LlamaSuggestionEngine.defaultConfidenceFloor, -.infinity)
        XCTAssertEqual(LlamaSuggestionEngine.resolvedConfidenceFloor(defaults), -.infinity)
    }

    func test_confidenceFloor_overrideWins_includingDisable() {
        defaults.set(-0.8, forKey: LlamaSuggestionEngine.confidenceFloorOverrideKey)
        XCTAssertEqual(LlamaSuggestionEngine.resolvedConfidenceFloor(defaults), -0.8)

        defaults.set(-Double.infinity, forKey: LlamaSuggestionEngine.confidenceFloorOverrideKey)
        XCTAssertEqual(LlamaSuggestionEngine.resolvedConfidenceFloor(defaults), -.infinity)
    }

    func test_argmaxStop_onByDefault_andDisableToggleWorks() {
        XCTAssertTrue(LlamaSuggestionEngine.resolvedStopAtArgmaxEOG(defaults))

        defaults.set(true, forKey: LlamaSuggestionEngine.argmaxStopDisabledKey)
        XCTAssertFalse(LlamaSuggestionEngine.resolvedStopAtArgmaxEOG(defaults))
    }
}
