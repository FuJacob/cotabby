import CryptoKit
import Foundation

/// File overview:
/// Encryption for everything conversation memory stores about messages.
///
/// Why: the store sits in Application Support, where file permissions keep other users out but not
/// other apps running as the same user, while the history it aggregates is protected at its source
/// (WhatsApp's and Mail's stores need Full Disk Access). Encrypting at rest keeps the copy as private
/// as the original.
///
/// How:
/// - One 256-bit root key in the Keychain (`KeychainTypingHistoryKeyStore`, service
///   `<bundle id>.memory`).
/// - Two subkeys, `HMAC-SHA256(root, label || 0x01)`: a single HKDF-Expand block, since the root
///   key is already uniformly random and the extract step adds nothing.
/// - `seal`/`open`: AES-256-GCM with a random 96-bit nonce, stored as `nonce || ciphertext || tag`
///   (`AES.GCM.SealedBox.combined`), for values that must be read back.
/// - `tag`: HMAC-SHA256 truncated to 128 bits (hex) for values that must be *matched* but never read
///   back (a title, a participant, a conversation key), so lookups work without plaintext.
nonisolated struct MemoryVault: Sendable {
    enum VaultError: LocalizedError {
        case keyMismatch
        case malformed

        var errorDescription: String? {
            switch self {
            case .keyMismatch: return "This memory was encrypted with a different key."
            case .malformed: return "A stored value could not be decrypted."
            }
        }
    }

    static let checkPlaintext = "cotabby-memory-key-check-v1"

    private let encryptionKey: SymmetricKey
    private let macKey: SymmetricKey

    init(rootKey: SymmetricKey) {
        encryptionKey = Self.expand(rootKey, label: "cotabby-memory enc")
        macKey = Self.expand(rootKey, label: "cotabby-memory mac")
    }

    private static func expand(_ root: SymmetricKey, label: String) -> SymmetricKey {
        var info = Data(label.utf8)
        info.append(0x01)
        return SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: info, using: root)))
    }

    func sealData(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: encryptionKey).combined else { throw VaultError.malformed }
        return combined
    }

    func openData(_ blob: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: encryptionKey)
    }

    func seal(_ text: String) throws -> Data {
        try sealData(Data(text.utf8))
    }

    func open(_ blob: Data) throws -> String {
        guard let text = String(data: try openData(blob), encoding: .utf8) else { throw VaultError.malformed }
        return text
    }

    /// A deterministic, non-reversible key for matching `value` (128 bits, lowercase hex).
    func tag(_ value: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: macKey)
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func checkValue() throws -> Data {
        try seal(Self.checkPlaintext)
    }

    func verify(_ checkValue: Data) throws {
        guard (try? open(checkValue)) == Self.checkPlaintext else { throw VaultError.keyMismatch }
    }
}
