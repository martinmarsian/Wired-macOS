//
//  ServerTrustStore.swift
//  Wired 3
//
//  Implements TOFU (Trust On First Use) for Wired server identity keys.
//  Stores the expected server fingerprint per host:port in UserDefaults.
//  On first connection: stores the fingerprint and allows the connection.
//  On subsequent connections: verifies the fingerprint and either allows
//  (match) or rejects (mismatch with strict mode) the connection.
//

import Foundation

/// Persistent store for server identity fingerprints (TOFU).
///
/// Keyed by "host:port" → SHA-256 hex fingerprint string.
/// Backed by UserDefaults under a dedicated suite so it is isolated
/// from the general app preferences.
struct ServerTrustStore {

    private static let suiteName = "fr.read-write.Wired3.TrustStore"
    private static let keyPrefix = "serverIdentity."

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - Storage key

    static func storageKey(host: String, port: Int) -> String {
        return keyPrefix + "\(host):\(port)"
    }

    // MARK: - CRUD

    /// Returns the stored fingerprint for this host:port, or nil if unknown.
    static func storedFingerprint(host: String, port: Int) -> String? {
        defaults.string(forKey: storageKey(host: host, port: port))
    }

    /// Stores (or updates) the fingerprint for this host:port.
    static func storeFingerprint(_ fingerprint: String, host: String, port: Int) {
        defaults.set(fingerprint, forKey: storageKey(host: host, port: port))
    }

    /// Removes the stored fingerprint for this host:port (forces re-trust on next connect).
    static func removeFingerprint(host: String, port: Int) {
        defaults.removeObject(forKey: storageKey(host: host, port: port))
    }

    // MARK: - Trust decision

    /// Evaluate whether to trust the server with the given fingerprint.
    ///
    /// - Parameters:
    ///   - fingerprint: hex SHA-256 of the server's identity public key
    ///   - host: server hostname
    ///   - port: server port
    ///   - strictIdentity: advertised by server — if true, a changed key is a hard failure
    ///
    /// - Returns: `.allow` to proceed, `.block(reason:)` to abort, `.newKey` on first-time trust
    enum TrustDecision {
        case allow
        case newKey(fingerprint: String)
        case changed(stored: String, received: String, strict: Bool)
    }

    static func evaluate(fingerprint: String, host: String, port: Int,
                         strictIdentity: Bool) -> TrustDecision {
        if let stored = storedFingerprint(host: host, port: port) {
            if stored == fingerprint {
                return .allow
            } else {
                return .changed(stored: stored, received: fingerprint, strict: strictIdentity)
            }
        } else {
            // First time — store and allow
            storeFingerprint(fingerprint, host: host, port: port)
            return .newKey(fingerprint: fingerprint)
        }
    }
}
