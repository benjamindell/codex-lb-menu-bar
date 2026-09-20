import Foundation
import Security

enum CredentialStoreError: LocalizedError {
    case keychain(OSStatus)
    case invalidPasswordData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "Couldn’t access the saved dashboard password in Keychain: \(detail)"
        case .invalidPasswordData:
            return "The saved dashboard password could not be read from Keychain."
        }
    }
}

/// Stores one dashboard password per configured server in the user's login
/// Keychain. The app never writes the password to UserDefaults or a file.
final class KeychainPasswordStore {
    private let service: String

    init(service: String = "com.codexlb.status.dashboard-password") {
        self.service = service
    }

    func password(for serverURL: String) throws -> String? {
        var query = baseQuery(for: serverURL)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.invalidPasswordData
        }
        return password
    }

    func save(_ password: String, for serverURL: String) throws {
        let passwordData = Data(password.utf8)
        let query = baseQuery(for: serverURL)
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw CredentialStoreError.keychain(updateStatus) }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialStoreError.keychain(addStatus) }
    }

    func deletePassword(for serverURL: String) throws {
        let status = SecItemDelete(baseQuery(for: serverURL) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(for serverURL: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialAccount(for: serverURL),
        ]
    }
}
