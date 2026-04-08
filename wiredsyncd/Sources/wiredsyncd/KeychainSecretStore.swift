import Foundation
import Security
protocol SecretStore {
    func readPassword(pairID: String) throws -> String?
    func writePassword(_ password: String, pairID: String, endpoint: SyncEndpoint) throws
    func deletePassword(pairID: String) throws
}

final class KeychainSecretStore {
    static let shared = KeychainSecretStore()

    private let service = "fr.read-write.wiredsyncd"

    private func account(for pairID: String) -> String {
        "sync-pair.\(pairID)"
    }

    func readPassword(pairID: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: pairID),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw error(status, action: "read")
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func writePassword(_ password: String, pairID: String, endpoint: SyncEndpoint) throws {
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: pairID)
        ]
        let updateAttributes: [CFString: Any] = [
            kSecValueData: Data(password.utf8),
            kSecAttrLabel: "wiredsyncd \(endpoint.login)@\(endpoint.serverURL)"
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw error(updateStatus, action: "update")
        }

        var addQuery = baseQuery
        for (key, value) in updateAttributes {
            addQuery[key] = value
        }
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw error(addStatus, action: "add")
        }
    }

    func deletePassword(pairID: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account(for: pairID)
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw error(status, action: "delete")
        }
    }

    private func error(_ status: OSStatus, action: String) -> NSError {
        let description = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(
            domain: "wiredsyncd.keychain",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Unable to \(action) sync credentials in Keychain: \(description)"]
        )
    }
}

extension KeychainSecretStore: SecretStore {}
