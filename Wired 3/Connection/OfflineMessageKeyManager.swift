//
//  OfflineMessageKeyManager.swift
//  Wired 3
//
//  Manages X25519 keypairs for E2E encrypted offline messages.
//  Private keys are stored in the macOS Keychain and never leave the device.
//
//  Keypairs are keyed by serverHost + username to prevent collision when
//  the same account name exists on multiple servers.
//

import CryptoKit
import Foundation
import Security

final class OfflineMessageKeyManager {
    static let shared = OfflineMessageKeyManager()

    private let service = "fr.read-write.Wired3"
    private let accountPrefix = "offline-key-"

    private init() {}

    // MARK: - Own keypair

    // Returns the existing keypair or generates and stores a new one.
    // serverHost must be provided to avoid keypair collision across servers.
    func loadOrCreateKeyPair(for username: String, serverHost: String) -> Curve25519.KeyAgreement.PrivateKey {
        if let existing = privateKey(for: username, serverHost: serverHost) {
            return existing
        }
        let newKey = Curve25519.KeyAgreement.PrivateKey()
        save(newKey, for: username, serverHost: serverHost)
        return newKey
    }

    func privateKey(for username: String, serverHost: String) -> Curve25519.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount(username: username, serverHost: serverHost),
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

    func publicKeyData(for username: String, serverHost: String) -> Data? {
        loadOrCreateKeyPair(for: username, serverHost: serverHost).publicKey.rawRepresentation
    }

    private func save(_ key: Curve25519.KeyAgreement.PrivateKey, for username: String, serverHost: String) {
        let account = keychainAccount(username: username, serverHost: serverHost)
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func keychainAccount(username: String, serverHost: String) -> String {
        "\(accountPrefix)\(serverHost)/\(username)"
    }

    // MARK: - TOFU for recipient public keys

    enum RecipientKeyTOFUResult {
        /// Fingerprint matches stored value, or first contact (fingerprint now persisted).
        case trusted
        /// Fingerprint differs from stored value — possible key substitution.
        case changed
    }

    /// Validates the recipient's public key against the last-seen fingerprint.
    /// On first contact the fingerprint is stored and `.trusted` is returned.
    /// If the key has changed since the last contact, `.changed` is returned
    /// and the fingerprint is NOT updated — the caller must decide whether to accept.
    func validateRecipientKey(_ keyData: Data, login: String, serverHost: String) -> RecipientKeyTOFUResult {
        let fingerprint = sha256Hex(keyData)
        let key = recipientFingerprintDefaultsKey(login: login, serverHost: serverHost)
        if let stored = UserDefaults.standard.string(forKey: key) {
            return stored == fingerprint ? .trusted : .changed
        }
        UserDefaults.standard.set(fingerprint, forKey: key)
        return .trusted
    }

    /// Clears the stored fingerprint for a recipient, e.g. after the user explicitly accepts
    /// a key change. The next call to `validateRecipientKey` will store the new fingerprint.
    func clearRecipientFingerprint(login: String, serverHost: String) {
        UserDefaults.standard.removeObject(forKey: recipientFingerprintDefaultsKey(login: login, serverHost: serverHost))
    }

    private func recipientFingerprintDefaultsKey(login: String, serverHost: String) -> String {
        "wired3.recipient-fingerprint.\(serverHost).\(login)"
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
