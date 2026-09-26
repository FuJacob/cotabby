import Foundation
import Security

/// Stores the optional endpoint bearer token in the user's Keychain.
///
/// The settings model owns this service for the app lifetime. The service name includes the bundle
/// identifier so Cotabby and Cotabby Dev do not silently share credentials, and the token is never
/// copied into UserDefaults or diagnostic logs.
@MainActor
final class KeychainOpenAICompatibleCredentialStore: OpenAICompatibleCredentialStoring {
    private let service: String
    private let account = "api-key"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.jacobfu.tabby") {
        service = "\(bundleIdentifier).openai-compatible-endpoint"
    }

    // Keep this explicit while Xcode 26.0–26.3 remain supported. Those toolchains can emit an
    // invalid isolated deinitializer when this class is retained through the credential protocol.
    deinit {}

    func readAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError(status: status)
        }
        return value
    }

    func saveAPIKey(_ apiKey: String?) throws {
        let normalized = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty else {
            try deleteAPIKey()
            return
        }

        let keyData = Data(normalized.utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: keyData]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialError(status: updateStatus)
        }

        var insert = identity
        insert[kSecValueData as String] = keyData
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialError(status: addStatus)
        }
    }

    func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError(status: status)
        }
    }
}

private struct KeychainCredentialError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "The endpoint API key could not be updated: \(message)"
        }
        return "The endpoint API key could not be updated (Keychain status \(status))."
    }
}
