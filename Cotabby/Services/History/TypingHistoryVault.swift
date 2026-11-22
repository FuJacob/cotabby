import CryptoKit
import Foundation
import Security

/// Encrypted on-disk storage for typing history.
///
/// Why encryption: the archive holds months of what the user wrote. Sealing it with AES-GCM under a
/// random 256-bit key that lives only in the login Keychain means a copied file, a backup, or another
/// app reading Application Support sees ciphertext. The Keychain item is `ThisDeviceOnly`, so the key
/// never syncs and the archive cannot be opened on another Mac.
///
/// The vault is a value type with no shared mutable state, so the store can load and save it on a
/// background task without touching the main actor. Errors are surfaced rather than swallowed: a
/// failed decrypt must not be mistaken for "no history" and then overwritten.
nonisolated struct TypingHistoryVault: Sendable {
    enum VaultError: Error, Equatable {
        case keychain(OSStatus)
        case corruptArchive
    }

    let fileURL: URL
    private let keyStore: any TypingHistoryKeyStore

    init(fileURL: URL, keyStore: any TypingHistoryKeyStore) {
        self.fileURL = fileURL
        self.keyStore = keyStore
    }

    /// The production vault: `Application Support/<app name>/TypingHistory.sealed`, keyed per bundle
    /// identifier so the release app and the dev build never share (or clobber) each other's key.
    static func standard(bundle: Bundle = .main) -> TypingHistoryVault {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Cotabby"
        let identifier = bundle.bundleIdentifier ?? "com.jacobfu.tabby"
        return TypingHistoryVault(
            fileURL: support.appendingPathComponent(appName).appendingPathComponent("TypingHistory.sealed"),
            keyStore: KeychainTypingHistoryKeyStore(service: "\(identifier).typing-history")
        )
    }

    /// Returns the stored records, or an empty list when nothing has been saved yet.
    func load() throws -> [TypingHistoryRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let key = try keyStore.existingKey() else {
            // A file without its key can never be opened again; report it instead of returning []
            // so the caller does not overwrite it as if it were empty.
            throw VaultError.corruptArchive
        }
        let sealed = try Data(contentsOf: fileURL)
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let plaintext = try? AES.GCM.open(box, using: key),
              let archive = try? JSONDecoder().decode(TypingHistoryArchive.self, from: plaintext)
        else {
            throw VaultError.corruptArchive
        }
        return archive.records
    }

    func save(_ records: [TypingHistoryRecord]) throws {
        let key = try keyStore.existingKey() ?? keyStore.createKey()
        let plaintext = try JSONEncoder().encode(TypingHistoryArchive(version: TypingHistoryArchive.currentVersion, records: records))
        guard let sealed = try AES.GCM.seal(plaintext, using: key).combined else { throw VaultError.corruptArchive }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Deletes the archive and its key. Removing the key too means even an undeleted copy of the
    /// file (Time Machine, a sync folder) can no longer be decrypted.
    func destroy() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        try keyStore.deleteKey()
    }
}

/// Where the vault's symmetric key lives. A protocol so tests can keep keys in memory instead of
/// writing items into the developer's login Keychain.
nonisolated protocol TypingHistoryKeyStore: Sendable {
    func existingKey() throws -> SymmetricKey?
    func createKey() throws -> SymmetricKey
    func deleteKey() throws
}

/// The production key store: one generic-password item in the login Keychain.
nonisolated struct KeychainTypingHistoryKeyStore: TypingHistoryKeyStore {
    let service: String
    private static let account = "archive-key"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
    }

    func existingKey() throws -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        // `item` is a CFData when the query asks for data; bridging to Data copies the bytes.
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            throw TypingHistoryVault.VaultError.keychain(status)
        }
        return SymmetricKey(data: data)
    }

    func createKey() throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        var attributes = baseQuery
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Cotabby typing history key"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw TypingHistoryVault.VaultError.keychain(status) }
        return key
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TypingHistoryVault.VaultError.keychain(status)
        }
    }
}
