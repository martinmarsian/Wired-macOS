//
//  SocketClient.swift
//  Wired-macOS
//
//  Created by Rafaël Warnault on 18/12/2025.
//  Copyright © 2025 Read-Write. All rights reserved.
//

import SwiftUI
import Foundation
import KeychainSwift
@preconcurrency import WiredSwift
import SocketSwift

actor SocketClient {
    @AppStorage("UserNick") var userNick: String = "Wired Swift"
    @AppStorage("UserStatus") var userStatus = ""
    @AppStorage("UserIcon") var userIcon: String?
    @AppStorage("ConnectionAttemptTimeout") var connectionAttemptTimeout: Double = 12.0
    
    private var connections: [UUID: WiredSwift.AsyncConnection] = [:]
    private var continuations: [UUID: AsyncThrowingStream<SocketEvent, Error>.Continuation] = [:]
    private var delegates: [UUID: DelegateProxy] = [:] // 🔑 rétention
        
    // MARK: - Connect

    func connect(
        configuration: ConnectionConfiguration
    ) -> AsyncThrowingStream<SocketEvent, Error> {

        let id = configuration.id
        let baseURL = configuration.url

        return AsyncThrowingStream { continuation in
            continuations[id] = continuation

            let proxy = DelegateProxy(
                id: id
            ) { [weak self] event in
                Task {
                    await self?.emit(event)
                }
            }

            let connection = WiredSwift.AsyncConnection(
                withSpec: spec!,
                delegate: proxy
            )

            if configuration.usesCustomIdentity {
                connection.nick = configuration.customNick.isEmpty ? userNick : configuration.customNick
                connection.status = configuration.customStatus
            } else {
                connection.nick = userNick
                connection.status = userStatus
            }
            connection.clientInfoDelegate = proxy
            connection.serverInfoDelegate = proxy
            if let userIcon = userIcon {
                connection.icon = userIcon
            }

            // SECURITY (A_009): TOFU — verify server identity fingerprint
            let host = configuration.hostname
            connection.serverTrustHandler = { fingerprint, isNewKey, strictIdentity in
                switch ServerTrustStore.evaluate(fingerprint: fingerprint,
                                                 host: host, port: 4871,
                                                 strictIdentity: strictIdentity) {
                case .allow:
                    return true

                case .newKey(let fp):
                    // First connection: fingerprint stored automatically
                    Logger.info("TOFU: stored new server identity for \(host) — \(fp)")
                    return true

                case .changed(let stored, let received, let strict):
                    Logger.warning("TOFU: server identity changed for \(host)!")
                    Logger.warning("  Expected : \(stored)")
                    Logger.warning("  Received : \(received)")
                    if strict {
                        Logger.error("TOFU: strict mode — aborting connection (possible MITM).")
                        return false
                    } else {
                        Logger.warning("TOFU: non-strict mode — updating stored fingerprint.")
                        ServerTrustStore.storeFingerprint(received, host: host, port: 4871)
                        return true
                    }
                }
            }

            connections[id] = connection
            delegates[id] = proxy

            continuation.onTermination = { @Sendable _ in
                Task { await self.disconnect(id: id) }
            }
            
            let cipher      = configuration.cipher
            let compression = configuration.compression
            let checksum    = configuration.checksum
            let password    = configuration.password
            let timeoutSeconds = max(3.0, connectionAttemptTimeout)

            DispatchQueue.global().async {
                let stateLock = NSLock()
                var didFinish = false

                func finishOnce(_ error: Error) {
                    stateLock.lock()
                    defer { stateLock.unlock() }
                    guard !didFinish else { return }
                    didFinish = true
                    continuation.finish(throwing: error)
                }

                let timeoutWorkItem = DispatchWorkItem {
                    connection.disconnect()
                    finishOnce(NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorTimedOut,
                        userInfo: [NSLocalizedDescriptionKey: "Connection timed out"]
                    ))
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + timeoutSeconds,
                    execute: timeoutWorkItem
                )

                let url = baseURL
                let keychainKey = "\(url.login)@\(url.hostname)"
                let keychain = KeychainSwift()
                if let password, !password.isEmpty {
                    url.password = password
                } else {
                    url.password = keychain.get(keychainKey) ?? ""
                }

                do {
                    try connection.connect(
                        withUrl: url,
                        cipher: cipher,
                        compression: compression,
                        checksum: checksum
                    )
                    stateLock.lock()
                    didFinish = true
                    stateLock.unlock()
                    timeoutWorkItem.cancel()
                } catch {
                    timeoutWorkItem.cancel()
                    // If auth failed while using a keychain password, the server-side password
                    // may have been cleared by an admin. Clear the stale keychain entry so the
                    // next connection attempt succeeds with an empty password automatically.
                    let isAuthFailure = error.localizedDescription.contains("mismatch") ||
                                       error.localizedDescription.contains("Authentication failed")
                    if isAuthFailure, !url.password.isEmpty, configuration.password == nil {
                        keychain.delete(keychainKey)
                    }
                    finishOnce(error)
                }
            }
        }
    }

    // MARK: - Emit

    public func emit(_ event: SocketEvent) {
        guard let continuation = continuations[event.id] else { return }
        continuation.yield(event)
    }

    // MARK: - Send

    func send(_ message: P7Message, on id: UUID) async throws -> P7Message? {
        guard let connection = connections[id] else { return nil }
        let response:P7Message? = try await connection.sendAsync(message)
        return response
    }

    // MARK: - Disconnect

    func disconnect(id: UUID) {
        connections[id]?.disconnect()
        connections[id] = nil
        delegates[id] = nil          // 🔥 libération delegate
        continuations[id]?.finish()
        continuations[id] = nil
    }
}
