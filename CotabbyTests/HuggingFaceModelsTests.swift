import Foundation
import XCTest
@testable import Cotabby

/// Tests for the HuggingFace REST response models: schema decoding, GGUF detection, size labels,
/// and direct-download URL construction.
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
        XCTAssertEqual(result.modelId, "org/model-GGUF")
        XCTAssertEqual(result.downloads, 1200)
        XCTAssertEqual(result.likes, 7)
        XCTAssertEqual(result.tags, ["gguf", "text-generation"])
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

    private func makeFile(path: String = "model.gguf", size: Int64 = 1_073_741_824) -> HFRepoFile {
        HFRepoFile(path: path, size: size, type: "file")
    }
}
