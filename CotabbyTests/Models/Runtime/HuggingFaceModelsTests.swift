import Foundation
import XCTest
@testable import Cotabby

/// Tests for the HuggingFace REST response models: schema decoding, GGUF detection, size labels,
/// direct-download URL construction, and which listed files the search flow offers for download.
final class HuggingFaceModelsTests: XCTestCase {
    func test_hfModelSearchResult_decodesTheSearchAPIShape() throws {
        let json = Data("""
        {
            "id": "org/model-GGUF",
            "modelId": "org/model-GGUF",
            "downloads": 1200,
            "likes": 7,
            "tags": ["gguf", "text-generation"]
        }
        """.utf8)

        let result = try JSONDecoder().decode(HFModelSearchResult.self, from: json)

        XCTAssertEqual(result.id, "org/model-GGUF")
        XCTAssertEqual(result.downloads, 1200)
        XCTAssertEqual(result.likes, 7)
    }

    func test_hfRepoFile_idIsThePathWithinTheRepo() {
        let file = makeFile(path: "weights/model.gguf")
        XCTAssertEqual(file.id, "weights/model.gguf")
    }

    func test_hfRepoFile_isGGUFMatchesExtensionCaseInsensitively() {
        XCTAssertTrue(makeFile(path: "weights/model.gguf").isGGUF)
        XCTAssertTrue(makeFile(path: "Model.GGUF").isGGUF)
        XCTAssertFalse(makeFile(path: "model.bin").isGGUF)
        // The extension must be a real suffix with the dot; a name merely containing "gguf" is not one.
        XCTAssertFalse(makeFile(path: "ggufmodel").isGGUF)
    }

    func test_hfRepoFile_sizeInGigabytesUsesBinaryGigabytes() {
        XCTAssertEqual(makeFile(size: 1_073_741_824).sizeInGigabytes, 1.0)
        XCTAssertEqual(makeFile(size: 536_870_912).sizeInGigabytes, 0.5)
    }

    func test_hfRepoFile_sizeLabelSwitchesToMegabytesBelowOneGigabyte() {
        XCTAssertEqual(makeFile(size: 1_610_612_736).sizeLabel, "1.5 GB")
        XCTAssertEqual(makeFile(size: 524_288_000).sizeLabel, "500 MB")
        // One byte under a binary gigabyte stays on the MB branch.
        XCTAssertEqual(makeFile(size: 1_073_741_823).sizeLabel, "1024 MB")
    }

    func test_hfRepoFile_downloadURLBuildsResolveMainEndpointWithDownloadFlag() {
        let url = makeFile(path: "subdir/model.gguf").downloadURL(repoId: "TheOrg/TheRepo")

        XCTAssertEqual(
            url?.absoluteString,
            "https://huggingface.co/TheOrg/TheRepo/resolve/main/subdir/model.gguf?download=true"
        )
    }

    func test_hfRepoFile_downloadURLEncodesPathsThatNeedEscaping() throws {
        let url = try XCTUnwrap(makeFile(path: "my model.gguf").downloadURL(repoId: "org/repo"))

        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertTrue(url.absoluteString.hasSuffix("?download=true"))
    }

    @MainActor
    func test_hfRepoFile_decodesLFSOidAndToleratesFilesWithoutLFS() throws {
        let json = Data("""
        [
            {
                "type": "file",
                "oid": "c32c15a89a0dc4deb80b47be95025ed67e19bdeb",
                "size": 3845328608,
                "lfs": {
                    "oid": "20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629",
                    "size": 3845328608,
                    "pointerSize": 135
                },
                "xetHash": "c86cda35866bbf0d61a9370cdc6d019548cf6cd9adfe25843f1f18984185fd73",
                "path": "model.gguf"
            },
            {"type": "file", "oid": "c16ef36eb3a012d3b558c31952889772bdbeddf0", "size": 2515, "path": "tiny.gguf"}
        ]
        """.utf8)

        let files = try JSONDecoder().decode([HFRepoFile].self, from: json)

        XCTAssertEqual(
            files.first?.lfs,
            HFLFSPointer(oid: "20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629", size: 3_845_328_608)
        )
        XCTAssertNil(files.last?.lfs)
    }

    @MainActor
    func test_searchService_verifiesAgainstTheLFSOidAndSize() throws {
        let file = makeFile(path: "weights/model.gguf", size: 987_654_321)
        let model = try XCTUnwrap(availableModel(for: file, repoId: "org/repo"))

        XCTAssertEqual(model.filename, "model.gguf")
        XCTAssertEqual(model.expectedSizeBytes, 987_654_321)
        XCTAssertEqual(model.sha256, Self.sampleOid)
    }

    @MainActor
    func test_searchService_usesTheFullSourceURLAsDownloadIdentity() throws {
        let file = makeFile(path: "weights/shared-name.gguf")
        let first = try XCTUnwrap(availableModel(for: file, repoId: "org/first"))
        let second = try XCTUnwrap(availableModel(for: file, repoId: "org/second"))

        XCTAssertEqual(first.filename, second.filename)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.id.contains("org/first/resolve/main/weights/shared-name.gguf"))
        XCTAssertTrue(second.id.contains("org/second/resolve/main/weights/shared-name.gguf"))
    }

    /// Fail closed: a file Hugging Face keeps outside LFS, or whose oid is not a SHA-256, has
    /// nothing to verify against and must not be offered.
    @MainActor
    func test_searchService_refusesFilesWithoutAVerifiableChecksum() {
        let plainGitFile = HFRepoFile(path: "tiny.gguf", size: 2_515)
        let gitBlobOid = HFRepoFile(
            path: "odd.gguf",
            size: 2_515,
            lfs: HFLFSPointer(oid: "c16ef36eb3a012d3b558c31952889772bdbeddf0", size: 2_515)
        )

        for file in [plainGitFile, gitBlobOid] {
            guard case .unavailable(let reason) = HuggingFaceSearchService.downloadOffer(for: file, repoId: "org/repo")
            else {
                return XCTFail("\(file.path) should not be offered without a SHA-256")
            }
            XCTAssertTrue(reason.contains("checksum"), reason)
        }
    }

    /// Display names are keyed by filename, so a third-party file named like a curated model would
    /// show up as that model. Refuse it, including case variants that APFS treats as the same file.
    @MainActor
    func test_searchService_refusesCuratedFilenamesFromOtherRepositories() throws {
        let curated = try XCTUnwrap(RuntimeModelCatalog.downloadableModels.first)
        for path in [curated.filename, curated.filename.uppercased(), "nested/\(curated.filename)"] {
            let offer = HuggingFaceSearchService.downloadOffer(for: makeFile(path: path), repoId: "someone/lookalike-GGUF")
            guard case .unavailable(let reason) = offer else {
                return XCTFail("\(path) from another repo must not install under \(curated.displayName)")
            }
            XCTAssertTrue(reason.contains(curated.displayName), reason)
        }
    }

    /// The curated file found through search installs the pinned catalog entry, not the unpinned
    /// `main` listing, so both entry points verify the same bytes and share one transfer state.
    @MainActor
    func test_searchService_offersThePinnedCatalogEntryForACuratedFile() throws {
        for curated in RuntimeModelCatalog.downloadableModels {
            let repoID = try XCTUnwrap(Self.huggingFaceRepoID(of: curated.downloadURL))
            let offer = HuggingFaceSearchService.downloadOffer(for: makeFile(path: curated.filename), repoId: repoID)
            XCTAssertEqual(offer, .available(curated), curated.filename)

            // The same leaf name elsewhere in the curated repo is a different file.
            let nested = HuggingFaceSearchService.downloadOffer(
                for: makeFile(path: "old/\(curated.filename)"),
                repoId: repoID
            )
            guard case .unavailable = nested else {
                return XCTFail("A nested copy of \(curated.filename) must not install under \(curated.displayName)")
            }
        }
    }

    @MainActor
    private func availableModel(for file: HFRepoFile, repoId: String) -> DownloadableRuntimeModel? {
        if case .available(let model) = HuggingFaceSearchService.downloadOffer(for: file, repoId: repoId) {
            return model
        }
        return nil
    }

    private static let sampleOid = "20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629"

    /// "/owner/repo/resolve/<revision>/<file>" -> "owner/repo".
    private static func huggingFaceRepoID(of url: URL) -> String? {
        let components = url.path.split(separator: "/")
        guard components.count >= 3, components[2] == "resolve" else {
            return nil
        }
        return "\(components[0])/\(components[1])"
    }

    private func makeFile(path: String = "model.gguf", size: Int64 = 1_073_741_824) -> HFRepoFile {
        HFRepoFile(path: path, size: size, lfs: HFLFSPointer(oid: Self.sampleOid, size: size))
    }
}
