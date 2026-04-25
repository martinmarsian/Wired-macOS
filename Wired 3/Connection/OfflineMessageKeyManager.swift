//
//  OfflineMessageKeyManager.swift
//  Wired 3
//
//  Manages X25519 keypairs for E2E encrypted offline messages.
//  Private keys are stored in the macOS Keychain and never leave the device.
//

import CryptoKit
import Foundation
import Security

final class OfflineMessageKeyManager {
    static let shared = OfflineMessageKeyManager()

    private let service = "fr.read-write.Wired3"
    private let accountPrefix = "offline-key-"

    private init() {}

    // Returns the existing keypair or generates and stores a new one.
    func loadOrCreateKeyPair(for username: String) -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = privateKey(for: username) {
            return existing
        }
        let newKey = Curve25519.KeyAgreement.PrivateKey()
        save(newKey, for: username)
        return newKey
    }

    func privateKey(for username: String) -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountPrefix + username,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        return key
    }

    func publicKeyData(for username: String) -> Data? {
        loadOrCreateKeyPair(for: username).publicKey.rawRepresentation
    }

    private func save(_ key: Curve25519.KeyAgreement.PrivateKey, for username: String) {
        let account = accountPrefix + username
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
