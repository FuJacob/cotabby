import Foundation
import XCTest
@testable import Cotabby

/// Covers `DeviceInfo`: the host snapshot (sanity-bounded, since values come from the real
/// machine), the pure version and memory formatting, and the query-item serialization that
/// feedback links rely on.
final class DeviceInfoTests: XCTestCase {
    // MARK: - Host snapshot

    func test_snapshot_reportsHostVersionAndMemory() throws {
        let snapshot = DeviceInfo.snapshot()

        XCTAssertFalse(try XCTUnwrap(snapshot.macosVersion).isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.memoryGB), 0)
    }

    func test_shortVersionString_dropsOnlyAZeroPatch() {
        func version(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
            OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
        }

        XCTAssertEqual(DeviceInfo.shortVersionString(version(14, 6, 0)), "14.6")
        XCTAssertEqual(DeviceInfo.shortVersionString(version(14, 6, 1)), "14.6.1")
        XCTAssertEqual(DeviceInfo.shortVersionString(version(15, 0, 0)), "15.0")
    }

    func test_wholeGigabytes_roundsToNearestAndTreatsZeroAsUnreported() {
        let gibibyte: UInt64 = 1_073_741_824

        XCTAssertEqual(DeviceInfo.wholeGigabytes(fromBytes: 16 * gibibyte), 16)
        XCTAssertEqual(DeviceInfo.wholeGigabytes(fromBytes: 16 * gibibyte + gibibyte / 4), 16)
        XCTAssertEqual(DeviceInfo.wholeGigabytes(fromBytes: 17 * gibibyte - gibibyte / 4), 17)
        XCTAssertNil(DeviceInfo.wholeGigabytes(fromBytes: 0))
    }

    func test_snapshot_reportsTrimmedHardwareIdentifiers() throws {
        let snapshot = DeviceInfo.snapshot()

        let model = try XCTUnwrap(snapshot.model, "hw.model should exist on every Mac")
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model, model.trimmingCharacters(in: .whitespacesAndNewlines))

        let chip = try XCTUnwrap(snapshot.chip, "machdep.cpu.brand_string should exist on macOS 14+")
        XCTAssertFalse(chip.isEmpty)
        XCTAssertEqual(chip, chip.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func test_snapshot_reportsAppVersionFromHostBundle() throws {
        let snapshot = DeviceInfo.snapshot()

        // Hosted tests run inside the Cotabby app bundle, which always carries a version string.
        let appVersion = try XCTUnwrap(snapshot.appVersion)
        XCTAssertFalse(appVersion.isEmpty)
    }

    // MARK: - Query-item serialization

    private let base = URL(string: "https://cotabby.app/feedback")!

    private func queryItems(of url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    func test_appending_addsAllFieldsInStableOrder() {
        let snapshot = DeviceInfo.Snapshot(
            appVersion: "1.2",
            macosVersion: "14.6",
            model: "Mac15,6",
            chip: "Apple M3 Pro",
            memoryGB: 36
        )

        let url = snapshot.appending(to: base)

        let items = queryItems(of: url)
        XCTAssertEqual(items.map(\.name), ["appVersion", "macosVersion", "model", "chip", "memoryGB"])
        XCTAssertEqual(items.map(\.value), ["1.2", "14.6", "Mac15,6", "Apple M3 Pro", "36"])
    }

    func test_appending_preservesExistingQueryItems() {
        let snapshot = DeviceInfo.Snapshot(
            appVersion: "2.0",
            macosVersion: nil,
            model: nil,
            chip: nil,
            memoryGB: nil
        )
        let baseWithQuery = URL(string: "https://cotabby.app/feedback?source=menu")!

        let url = snapshot.appending(to: baseWithQuery)

        let items = queryItems(of: url)
        XCTAssertEqual(items.map(\.name), ["source", "appVersion"])
        XCTAssertEqual(items.map(\.value), ["menu", "2.0"])
    }

    func test_appending_omitsNilAndEmptyFields() {
        // Empty strings and nils must both vanish so the landing page never receives blank values.
        let snapshot = DeviceInfo.Snapshot(
            appVersion: "",
            macosVersion: "15.0",
            model: nil,
            chip: "",
            memoryGB: 16
        )

        let url = snapshot.appending(to: base)

        let items = queryItems(of: url)
        XCTAssertEqual(items.map(\.name), ["macosVersion", "memoryGB"])
        XCTAssertEqual(items.map(\.value), ["15.0", "16"])
    }

    func test_appending_returnsBaseUnchangedWhenSnapshotIsEmpty() {
        let snapshot = DeviceInfo.Snapshot(
            appVersion: nil,
            macosVersion: nil,
            model: nil,
            chip: nil,
            memoryGB: nil
        )

        let url = snapshot.appending(to: base)

        XCTAssertEqual(url, base)
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    func test_appending_keepsExistingQueryWhenSnapshotAddsNothing() {
        let snapshot = DeviceInfo.Snapshot(appVersion: nil, macosVersion: "", model: nil, chip: nil, memoryGB: nil)
        let baseWithQuery = URL(string: "https://cotabby.app/feedback?source=menu")!

        XCTAssertEqual(snapshot.appending(to: baseWithQuery), baseWithQuery)
    }

    func test_appending_preservesFragmentAfterTheQuery() {
        let snapshot = DeviceInfo.Snapshot(appVersion: "1.0", macosVersion: nil, model: nil, chip: nil, memoryGB: nil)
        let baseWithFragment = URL(string: "https://cotabby.app/feedback#form")!

        let url = snapshot.appending(to: baseWithFragment)

        XCTAssertEqual(url.absoluteString, "https://cotabby.app/feedback?appVersion=1.0#form")
    }

    func test_appending_percentEncodesValuesLosslessly() {
        let snapshot = DeviceInfo.Snapshot(
            appVersion: nil,
            macosVersion: nil,
            model: nil,
            chip: "Intel(R) Core(TM) i9 & friends",
            memoryGB: nil
        )

        let url = snapshot.appending(to: base)

        // The raw absolute string must not contain unescaped spaces, and decoding must round-trip
        // the original value exactly.
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertEqual(queryItems(of: url).first?.value, "Intel(R) Core(TM) i9 & friends")
    }
}
