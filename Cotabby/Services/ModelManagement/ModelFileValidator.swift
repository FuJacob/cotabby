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
/// Why both validators take optional expected values:
/// `DownloadableRuntimeModel.expectedSizeBytes` and `.sha256` are optional so
/// future catalog entries can land without metadata immediately. When the
/// expected value is nil, the validator no-ops — better than failing every
/// install just because metadata wasn't filled in yet. The catalog is the
/// authoritative source of "what should be true about this file."
enum ModelFileValidator {

    enum ValidationError: LocalizedError {
        case sizeMismatch(expected: Int64, actual: Int64)
        case checksumMismatch(expected: String, actual: String)
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
    /// The curated catalog ships with nil `expectedSizeBytes`/`sha256`, so those validators no-op and
    /// the only remaining integrity gate is the HTTP status check — which does NOT catch a body the
    /// server truncated while ending the transfer "cleanly" (an HTTP/2 stream reset or a proxy closing
    /// the connection both surface as a finished task with no error). Comparing the on-disk size to the
    /// declared length closes that gap without needing catalog metadata. No-op when the length is
    /// unknown (`expectedContentLength <= 0`, i.e. `NSURLSessionTransferSizeUnknown`).
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

    /// Throws if the file's SHA-256 differs from `expectedSHA256` (case-insensitive).
    /// No-op when `expectedSHA256` is nil.
    ///
    /// Streams the file in 1 MB chunks so the largest curated GGUF (~4.5 GB)
    /// doesn't get fully loaded into memory.
    static func validateSHA256(of url: URL, expectedSHA256: String?) throws {
        guard let expectedSHA256 else {
            return
        }
        let actualHex = try sha256Hex(of: url)
        // Lowercase comparison: HuggingFace returns hex in lowercase, but we
        // accept either case in the catalog so a hand-pasted upper-case
        // checksum won't silently fail every download.
        if actualHex.lowercased() != expectedSHA256.lowercased() {
            throw ValidationError.checksumMismatch(expected: expectedSHA256, actual: actualHex)
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
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                throw ValidationError.fileUnreadable(url)
            }
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
