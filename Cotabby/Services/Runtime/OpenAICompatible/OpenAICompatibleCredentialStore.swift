import Foundation
import Security

/// Stores the optional endpoint bearer token, and the server the user approved, in the Keychain.
///
/// The settings model owns this service for the app lifetime. The service name includes the bundle
/// identifier so Cotabby and Cotabby Dev do not silently share credentials, and the token is never
/// copied into UserDefaults or diagnostic logs. The approved-server record is not secret, but it sits
/// here rather than in UserDefaults because it is the one value a same-user process must not be able
/// to rewrite with `defaults write`.
@MainActor
final class KeychainOpenAICompatibleCredentialStore: OpenAICompatibleCredentialStoring {
    private let service: String
    private let apiKeyAccount = "api-key"
    private let approvedOriginAccount = "approved-origin"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.jacobfu.tabby") {
        service = "\(bundleIdentifier).openai-compatible-endpoint"
    }

    // Keep this explicit while Xcode 26.0–26.3 remain supported. Those toolchains can emit an
    // invalid isolated deinitializer when this class is retained through the credential protocol.
    deinit {}

    func readAPIKey() throws -> String? {
        try readString(account: apiKeyAccount, subject: .apiKey)
    }

    func saveAPIKey(_ apiKey: String?) throws {
        let normalized = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else {
            try deleteAPIKey()
            return
        }
        try saveString(normalized, account: apiKeyAccount, subject: .apiKey)
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(identity(account: apiKeyAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError(status: status, subject: .apiKey)
        }
    }

    func readApprovedOriginRecord() throws -> String? {
        try readString(account: approvedOriginAccount, subject: .approvedServer)
    }

    func saveApprovedOriginRecord(_ record: String) throws {
        try saveString(record, account: approvedOriginAccount, subject: .approvedServer)
    }

    // MARK: - Generic password items

    private func identity(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func readString(account: String, subject: KeychainCredentialError.Subject) throws -> String? {
        var query = identity(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError(status: status, subject: subject)
        }
        return value
    }

    /// Update first so an existing item keeps its access control list; add only when it is missing.
    private func saveString(_ value: String, account: String, subject: KeychainCredentialError.Subject) throws {
        let data = Data(value.utf8)
        let itemIdentity = identity(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(itemIdentity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialError(status: updateStatus, subject: subject)
        }

        var insert = itemIdentity
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialError(status: addStatus, subject: subject)
        }
    }
}

private struct KeychainCredentialError: LocalizedError {
    nonisolated enum Subject {
        case apiKey
        case approvedServer

        var displayName: String {
            switch self {
            case .apiKey: return "The endpoint API key"
            case .approvedServer: return "The approved endpoint server"
            }
        }
    }

    let status: OSStatus
    let subject: Subject

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(subject.displayName) could not be updated: \(message)"
        }
        return "\(subject.displayName) could not be updated (Keychain status \(status))."
    }
}
