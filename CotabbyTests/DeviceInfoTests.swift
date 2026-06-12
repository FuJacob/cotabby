import Foundation
import XCTest
@testable import Cotabby

/// Covers both halves of `DeviceInfo`: the host snapshot (sanity-bounded, since values come from
/// the real machine) and the pure query-item serialization that feedback links rely on.
final class DeviceInfoTests: XCTestCase {
    // MARK: - Host snapshot

    func test_snapshot_reportsShortMacOSVersionString() {
        let snapshot = DeviceInfo.snapshot()

        // Same composition rule as production: the point is locking the short "14.6" format
        // (no "Version" prefix, no build number, patch omitted when zero).
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let expected: String
        if version.patchVersion == 0 {
            expected = "\(version.majorVersion).\(version.minorVersion)"
        } else {
            expected = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        }
        XCTAssertEqual(snapshot.macosVersion, expected)
    }

    func test_snapshot_reportsWholeGigabyteMemory() {
        let snapshot = DeviceInfo.snapshot()

        let expected = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0).rounded())
        XCTAssertEqual(snapshot.memoryGB, expected)
        XCTAssertGreaterThan(snapshot.memoryGB ?? 0, 0)
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
