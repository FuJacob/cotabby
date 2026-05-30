import Foundation
import Logging

/// File overview:
/// Short, human-readable correlation IDs for inline-completion requests.
///
/// One ID is generated when `SuggestionCoordinator` decides to ask the engine for a completion, and
/// every log line touched by that request — coordinator state transitions, router selection, engine
/// generation, LLM I/O capture, insertion — stamps the same ID into its metadata under
/// `request_id`. That lets an AI debugger pull "everything that happened for one suggestion" with
/// one `jq` filter, instead of guessing at timing windows.
///
/// Format is `req_` + 8 lowercase base32 characters derived from a fresh UUID. Short enough to copy
/// from a log line, long enough to make collisions inside a session essentially impossible.
enum RequestID {
    /// Returns a new short correlation ID, e.g. `req_a3f9k2lq`.
    static func generate() -> String {
        let uuid = UUID().uuid
        // First 5 raw bytes encode to exactly 8 base32 characters (5 bytes = 40 bits = 8 * 5 bits).
        let bytes: [UInt8] = [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4]
        return "req_" + base32(bytes)
    }

    /// Crockford-style base32 without padding, lowercased. Chosen over hex for compactness and over
    /// base64 because base64 can include `+` / `/` which read poorly in log lines and grep queries.
    private static let alphabet = Array("0123456789abcdefghjkmnpqrstvwxyz")

    private static func base32(_ bytes: [UInt8]) -> String {
        var output = ""
        var buffer: UInt64 = 0
        var bitsLeft = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt64(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                bitsLeft -= 5
                let index = Int((buffer >> UInt64(bitsLeft)) & 0x1F)
                output.append(alphabet[index])
            }
        }
        if bitsLeft > 0 {
            let index = Int((buffer << UInt64(5 - bitsLeft)) & 0x1F)
            output.append(alphabet[index])
        }
        return output
    }
}

extension Logger.Metadata {
    /// Convenience for the common "stamp a `request_id` field on one log line" pattern.
    /// Returns a fresh metadata dict so callers can pass `Logger.Metadata.requestID(id)` inline.
    static func requestID(_ id: String) -> Logger.Metadata {
        ["request_id": .string(id)]
    }
}
