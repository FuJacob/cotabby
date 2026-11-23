import Foundation
import CryptoKit

/// File overview:
/// Verifies a downloaded GGUF file against expected size and SHA-256 metadata
/// before the download manager promotes it to the installed location.
///
/// Why both size and checksum:
/// Size is a fast pre-check that catches truncated downloads (cancelled mid-
/// transfer, server hung up). SHA-256 is the real integrity guarantee against
/// silent corruption — bit flips, mirror-side substitution, partial writes
/// that happen to land at the right byte count. Either alone is insufficient:
/// matching size with wrong contents is plausible for any transport bug, and
/// computing SHA-256 first is wasteful when bytes-on-disk is wrong.
///
/// Why the checksum fails closed but the size check does not:
/// The downloaded GGUF is parsed by llama.cpp inside the process that holds
/// Cotabby's Accessibility, Input Monitoring and Screen Recording grants, and
/// the model decides what Cotabby offers to type into other apps. So "we had
/// nothing to compare against" must mean "don't install", never "assume it's
/// fine". Every download Cotabby offers carries a digest: the curated catalog
/// pins one per commit, and Hugging Face search uses the LFS oid from the tree
/// API. Size stays optional because it is only a fast pre-check; the hash is
/// the gate.
nonisolated enum ModelFileValidator {

    enum ValidationError: LocalizedError {
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMismatch(expected: String, actual: String)
        case missingChecksum
        case fileUnreadable(URL)

        var errorDescription: String? {
            switch self {
            case let .sizeMismatch(expected, actual):
                return "Downloaded file is \(actual) bytes; expected \(expected). The download may have been truncated."
            case let .checksumMismatch(expected, actual):
                let expectedShort = String(expected.lowercased().prefix(16))
                let actualShort = String(actual.lowercased().prefix(16))
                return "Downloaded file's checksum (\(actualShort)…) doesn't match the " +
                    "expected (\(expectedShort)…). The file may be corrupt."
            case .missingChecksum:
                return "Cotabby has no checksum for this file, so it can't verify the download and won't install it."
            case let .fileUnreadable(url):
                return "Couldn't read \(url.lastPathComponent) for validation."
            }
        }
    }

    /// Throws if the file's byte size differs from `expectedBytes`.
    /// No-op when `expectedBytes` is nil.
    static func validateSize(
        of url: URL,
        expectedBytes: Int64?,
        fileManager: FileManager = .default
    ) throws {
        guard let expectedBytes else {
            return
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            throw ValidationError.fileUnreadable(url)
        }
        guard let actualNumber = attributes[.size] as? NSNumber else {
            throw ValidationError.fileUnreadable(url)
        }
        let actualBytes = actualNumber.int64Value
        if actualBytes != expectedBytes {
            throw ValidationError.sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }
    }

    /// Throws if the file's byte size differs from the server's declared `Content-Length`.
    ///
    /// The HTTP status check does NOT catch a body the server truncated while ending the transfer
    /// "cleanly" (an HTTP/2 stream reset or a proxy closing the connection both surface as a finished
    /// task with no error). Comparing the on-disk size to the declared length reports that as a
    /// truncation before the slower SHA-256 pass would report it as a mismatch. No-op when the length
    /// is unknown (`expectedContentLength <= 0`, i.e. `NSURLSessionTransferSizeUnknown`).
    static func validateCompleteness(
        of url: URL,
        declaredContentLength: Int64,
        fileManager: FileManager = .default
    ) throws {
        guard declaredContentLength > 0 else {
            return
        }
        try validateSize(of: url, expectedBytes: declaredContentLength, fileManager: fileManager)
    }

    /// Throws unless the file's SHA-256 equals `expectedSHA256` (case-insensitive).
    /// Fails closed: a nil or malformed expected digest throws `.missingChecksum`
    /// instead of passing, so a catalog entry or search result that lost its
    /// digest can never install unverified bytes.
    ///
    /// Streams the file in 1 MB chunks so the largest curated GGUF (~5.3 GB)
    /// doesn't get fully loaded into memory.
    static func validateSHA256(of url: URL, expectedSHA256: String?) throws {
        guard let expectedSHA256, isSHA256Hex(expectedSHA256) else {
            throw ValidationError.missingChecksum
        }
        let actualHex = try sha256Hex(of: url)
        // Lowercase comparison: HuggingFace returns hex in lowercase, but we
        // accept either case in the catalog so a hand-pasted upper-case
        // checksum won't silently fail every download.
        if actualHex.lowercased() != expectedSHA256.lowercased() {
            throw ValidationError.checksumMismatch(expected: expectedSHA256, actual: actualHex)
        }
    }

    /// True for a 64-character hex string in either case. Shared with the Hugging Face search
    /// flow so a listing whose LFS oid is not a SHA-256 is refused before any bytes download.
    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "a")...UInt8(ascii: "f"),
                 UInt8(ascii: "A")...UInt8(ascii: "F"):
                return true
            default:
                return false
            }
        }
    }

    /// Computes the SHA-256 of the file as a lowercase hex string.
    /// Streams the file in chunks so memory stays bounded regardless of size.
    private static func sha256Hex(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ValidationError.fileUnreadable(url)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        // 1 MB keeps memory bounded while avoiding excessive read syscalls.
        let chunkSize = 1024 * 1024
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            // `FileHandle` can hand back bridged, autoreleased buffers. This loop runs as one job on
            // a detached task, whose pool may not drain until the whole multi-GB hash finishes, so
            // each chunk gets its own pool to keep peak memory at about one chunk.
            let reachedEnd = try autoreleasepool { () throws -> Bool in
                let chunk: Data
                do {
                    chunk = try handle.read(upToCount: chunkSize) ?? Data()
                } catch {
                    throw ValidationError.fileUnreadable(url)
                }
                if chunk.isEmpty {
                    return true
                }
                hasher.update(data: chunk)
                return false
            }
            if reachedEnd {
                break
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
