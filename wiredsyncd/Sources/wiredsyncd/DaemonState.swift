import Foundation
final class DaemonState {
    let paths: PathLayout
    let store: SQLiteStore
    let secrets: SecretStore
    private var config: DaemonConfig
    private var _running: Bool = true
    private var logs: [String] = []
    private var runtimeStatuses: [String: PairRuntimeStatus] = [:]
    private let lock = NSLock()

    init(paths: PathLayout, store: SQLiteStore, secrets: SecretStore = KeychainSecretStore.shared) throws {
        self.paths = paths
        self.store = store
        self.secrets = secrets
        self.config = try Self.loadConfig(path: paths.configPath)
        try migratePersistedCredentialsIfNeeded()
        for pair in config.pairs {
            try store.upsert(pair: pair)
            runtimeStatuses[pair.id] = PairRuntimeStatus(pairID: pair.id, state: pair.paused ? .paused : .disconnected)
        }
    }

    private static func loadConfig(path: URL) throws -> DaemonConfig {
        guard FileManager.default.fileExists(atPath: path.path) else { return DaemonConfig() }
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DaemonConfig.self, from: data)
    }

    private func saveConfigLocked() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: paths.configPath, options: .atomic)
    }

    private func migratePersistedCredentialsIfNeeded() throws {
        var migratedPairs: [SyncPair] = []
        var didMigrate = false

        for var pair in config.pairs {
            if !pair.endpoint.password.isEmpty {
                try persistCredential(pair.endpoint.password, for: pair.id, endpoint: pair.endpoint)
                pair.endpoint.password = ""
                didMigrate = true
                appendLog("pair.credentials_migrated id=\(pair.id)")
            }
            migratedPairs.append(pair)
        }

        config.pairs = migratedPairs

        guard didMigrate else { return }

        lock.lock()
        do {
            try saveConfigLocked()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
    }

    private func persistCredential(_ password: String, for pairID: String, endpoint: SyncEndpoint) throws {
        if password.isEmpty {
            try secrets.deletePassword(pairID: pairID)
        } else {
            try secrets.writePassword(password, pairID: pairID, endpoint: endpoint)
        }
    }

    func appendLog(_ line: String) {
        let formatted = "\(ISO8601DateFormatter().string(from: Date())) \(line)"
        lock.lock()
        logs.append(formatted)
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
        lock.unlock()
        fputs("wiredsyncd: \(formatted)\n", stdout)
        fflush(stdout)
    }

    func tail(count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(logs.suffix(max(0, count)))
    }

    func status() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let connectedStates: Set<PairConnectionState> = [.connected, .syncing]
        let connectedPairs = runtimeStatuses.values.filter { connectedStates.contains($0.state) }.count
        let reconnectingPairs = runtimeStatuses.values.filter { $0.state == .reconnecting }.count
        let errorPairs = runtimeStatuses.values.filter { $0.state == .error }.count
        return [
            "version": kDaemonVersion,
            "pairs_count": config.pairs.count,
            "active_pairs": runtimeStatuses.values.filter { $0.state != .paused }.count,
            "connected_pairs": connectedPairs,
            "reconnecting_pairs": reconnectingPairs,
            "error_pairs": errorPairs,
            "queue_depth": store.queueDepth(),
            "socket_path": paths.socketPath.path,
            "config_path": paths.configPath.path,
            "state_path": paths.statePath.path,
            "running": _running
        ]
    }

    func snapshotPairs() -> [SyncPair] {
        lock.lock()
        defer { lock.unlock() }
        return config.pairs
    }

    func pair(id: String) -> SyncPair? {
        lock.lock()
        defer { lock.unlock() }
        return config.pairs.first(where: { $0.id == id })
    }

    func runtimeStatus(pairID: String) -> PairRuntimeStatus? {
        lock.lock()
        defer { lock.unlock() }
        return runtimeStatuses[pairID]
    }

    func runtimeStatusesSnapshot() -> [String: PairRuntimeStatus] {
        lock.lock()
        defer { lock.unlock() }
        return runtimeStatuses
    }

    func setRuntimeStatus(
        pairID: String,
        state: PairConnectionState? = nil,
        lastError: String?? = nil,
        retryCount: Int? = nil,
        nextRetryAt: Date?? = nil,
        lastConnectedAt: Date?? = nil,
        lastSyncStartedAt: Date?? = nil,
        lastSyncCompletedAt: Date?? = nil,
        remoteInventoryAvailable: Bool?? = nil
    ) {
        lock.lock()
        var runtime = runtimeStatuses[pairID] ?? PairRuntimeStatus(pairID: pairID)
        if let state {
            runtime.state = state
        }
        if let lastError {
            runtime.lastError = lastError
        }
        if let retryCount {
            runtime.retryCount = retryCount
        }
        if let nextRetryAt {
            runtime.nextRetryAt = nextRetryAt
        }
        if let lastConnectedAt {
            runtime.lastConnectedAt = lastConnectedAt
        }
        if let lastSyncStartedAt {
            runtime.lastSyncStartedAt = lastSyncStartedAt
        }
        if let lastSyncCompletedAt {
            runtime.lastSyncCompletedAt = lastSyncCompletedAt
        }
        if let remoteInventoryAvailable {
            runtime.remoteInventoryAvailable = remoteInventoryAvailable
        }
        runtimeStatuses[pairID] = runtime
        lock.unlock()
    }

    func clearRuntimeStatus(pairID: String) {
        lock.lock()
        runtimeStatuses.removeValue(forKey: pairID)
        lock.unlock()
    }

    func addPair(
        remotePath: String,
        localPath: String,
        mode: SyncMode,
        deleteRemoteEnabled: Bool,
        excludePatterns: [String] = [],
        endpoint: SyncEndpoint
    ) throws -> SyncPair {
        let now = Date()
        let persistableEndpoint = SyncEndpoint(serverURL: endpoint.serverURL, login: endpoint.login, password: "")
        var pair = SyncPair(
            id: UUID().uuidString,
            remotePath: remotePath,
            localPath: localPath,
            mode: mode,
            deleteRemoteEnabled: deleteRemoteEnabled,
            excludePatterns: excludePatterns,
            endpoint: persistableEndpoint,
            paused: false,
            createdAt: now,
            updatedAt: now
        )
        var dedupLogLines: [String] = []
        var staleIDs: [String] = []

        lock.lock()
        do {
            let matchingIndexes = config.pairs.enumerated().compactMap { index, item -> Int? in
                let sameRemote = item.remotePath == remotePath
                let sameLocal = item.localPath == localPath
                let sameServer = item.endpoint.serverURL == persistableEndpoint.serverURL
                let sameLogin = item.endpoint.login == persistableEndpoint.login
                return (sameRemote && sameLocal && sameServer && sameLogin) ? index : nil
            }

            if let index = matchingIndexes.first {
                pair = config.pairs[index]
                let policyChanged = pair.mode != mode || pair.deleteRemoteEnabled != deleteRemoteEnabled || pair.excludePatterns != excludePatterns
                pair.mode = mode
                pair.deleteRemoteEnabled = deleteRemoteEnabled
                pair.excludePatterns = excludePatterns
                pair.endpoint = persistableEndpoint
                pair.paused = false
                pair.updatedAt = now
                config.pairs[index] = pair
                if policyChanged {
                    staleIDs.append("clear:\(pair.id)")
                    dedupLogLines.append("pair.policy_reset_cache id=\(pair.id)")
                }

                // Keep one logical pair per (server_url, login, remote_path, local_path).
                if matchingIndexes.count > 1 {
                    let staleIndexes = matchingIndexes.dropFirst().sorted(by: >)
                    for staleIndex in staleIndexes {
                        let stale = config.pairs.remove(at: staleIndex)
                        staleIDs.append(stale.id)
                        dedupLogLines.append("pair.dedup removed_id=\(stale.id) kept_id=\(pair.id)")
                    }
                }
            } else {
                config.pairs.append(pair)
            }
            try persistCredential(endpoint.password, for: pair.id, endpoint: persistableEndpoint)
            try saveConfigLocked()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        for staleID in staleIDs {
            if staleID.hasPrefix("clear:") {
                try store.clearUploadedSnapshots(pairID: String(staleID.dropFirst("clear:".count)))
            } else {
                try secrets.deletePassword(pairID: staleID)
                try store.remove(id: staleID)
                clearRuntimeStatus(pairID: staleID)
            }
        }
        try store.upsert(pair: pair)
        try store.enqueue(pairID: pair.id, opKind: "rescan", payload: "{}")
        setRuntimeStatus(pairID: pair.id, state: .disconnected, lastError: .some(nil), retryCount: 0, nextRetryAt: .some(nil), remoteInventoryAvailable: .some(nil))
        for line in dedupLogLines {
            appendLog(line)
        }
        appendLog("pair.add id=\(pair.id) mode=\(pair.mode.rawValue) delete_remote=\(pair.deleteRemoteEnabled) remote=\(pair.remotePath)")
        return pair
    }

    func removePair(id: String) throws -> Bool {
        lock.lock()
        guard let index = config.pairs.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return false
        }
        config.pairs.remove(at: index)
        do {
            try saveConfigLocked()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        try secrets.deletePassword(pairID: id)
        try store.remove(id: id)
        clearRuntimeStatus(pairID: id)
        appendLog("pair.remove id=\(id)")
        return true
    }

    func removePairs(remotePath: String, serverURL: String?, login: String?) throws -> [String] {
        lock.lock()
        let normalizedServer = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexes = config.pairs.enumerated().compactMap { index, pair -> Int? in
            guard pair.remotePath == remotePath else { return nil }
            if let normalizedServer, !normalizedServer.isEmpty {
                guard pair.endpoint.serverURL == normalizedServer else { return nil }
            }
            if let normalizedLogin, !normalizedLogin.isEmpty {
                guard pair.endpoint.login == normalizedLogin else { return nil }
            }
            return index
        }
        guard !indexes.isEmpty else {
            lock.unlock()
            return []
        }

        var removedIDs: [String] = []
        for index in indexes.sorted(by: >) {
            let pair = config.pairs.remove(at: index)
            removedIDs.append(pair.id)
        }
        do {
            try saveConfigLocked()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        for removedID in removedIDs {
            try secrets.deletePassword(pairID: removedID)
            try store.remove(id: removedID)
            clearRuntimeStatus(pairID: removedID)
        }
        appendLog("pair.remove_by_remote remote=\(remotePath) count=\(removedIDs.count)")
        return removedIDs
    }

    func updatePairPolicy(
        remotePath: String,
        serverURL: String?,
        login: String?,
        mode: SyncMode,
        deleteRemoteEnabled: Bool,
        excludePatterns: [String] = []
    ) throws -> [String] {
        lock.lock()
        let normalizedServer = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines)

        var updatedPairs: [SyncPair] = []
        for index in config.pairs.indices {
            let pair = config.pairs[index]
            guard pair.remotePath == remotePath else { continue }
            if let normalizedServer, !normalizedServer.isEmpty, pair.endpoint.serverURL != normalizedServer {
                continue
            }
            if let normalizedLogin, !normalizedLogin.isEmpty, pair.endpoint.login != normalizedLogin {
                continue
            }
            guard pair.mode != mode || pair.deleteRemoteEnabled != deleteRemoteEnabled || pair.excludePatterns != excludePatterns else { continue }
            config.pairs[index].mode = mode
            config.pairs[index].deleteRemoteEnabled = deleteRemoteEnabled
            config.pairs[index].excludePatterns = excludePatterns
            config.pairs[index].updatedAt = Date()
            updatedPairs.append(config.pairs[index])
        }

        guard !updatedPairs.isEmpty else {
            lock.unlock()
            return []
        }

        do {
            try saveConfigLocked()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        for pair in updatedPairs {
            try store.upsert(pair: pair)
            try store.clearUploadedSnapshots(pairID: pair.id)
            try store.enqueue(pairID: pair.id, opKind: "rescan", payload: "{}")
            appendLog("pair.update_policy id=\(pair.id) mode=\(pair.mode.rawValue) delete_remote=\(pair.deleteRemoteEnabled) remote=\(pair.remotePath)")
        }

        return updatedPairs.map(\.id)
    }

    func renamePairRemotePath(
        oldPath: String,
        newPath: String,
        serverURL: String?,
        login: String?
    ) throws -> [String] {
        lock.lock()
        let normalizedServer = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLogin  = login?.trimmingCharacters(in: .whitespacesAndNewlines)

        var renamedPairs: [SyncPair] = []
        for index in config.pairs.indices {
            let pair = config.pairs[index]
            guard pair.remotePath == oldPath else { continue }
            if let normalizedServer, !normalizedServer.isEmpty,
               pair.endpoint.serverURL != normalizedServer { continue }
            if let normalizedLogin, !normalizedLogin.isEmpty,
               pair.endpoint.login != normalizedLogin { continue }
            config.pairs[index].remotePath = newPath
            config.pairs[index].updatedAt = Date()
            renamedPairs.append(config.pairs[index])
        }

        guard !renamedPairs.isEmpty else {
            lock.unlock()
            return []
        }

        do {
            try saveConfigLocked()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()

        for pair in renamedPairs {
            try store.upsert(pair: pair)
            appendLog("pair.rename_remote id=\(pair.id) old=\(oldPath) new=\(newPath)")
        }
        return renamedPairs.map(\.id)
    }

    func setPaused(id: String, paused: Bool) throws -> Bool {
        lock.lock()
        guard let index = config.pairs.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return false
        }
        config.pairs[index].paused = paused
        config.pairs[index].updatedAt = Date()
        let pair = config.pairs[index]
        do {
            try saveConfigLocked()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        try store.upsert(pair: pair)
        setRuntimeStatus(pairID: id, state: paused ? .paused : .disconnected, lastError: .some(nil), retryCount: 0, nextRetryAt: .some(nil))
        appendLog("pair.\(paused ? "pause" : "resume") id=\(id)")
        return true
    }

    func reload() throws {
        let loaded = try Self.loadConfig(path: paths.configPath)
        lock.lock()
        config = loaded
        let loadedPairs = config.pairs
        runtimeStatuses = Dictionary(uniqueKeysWithValues: loadedPairs.map { pair in
            let previous = runtimeStatuses[pair.id]
            let state: PairConnectionState = pair.paused ? .paused : (previous?.state == .paused ? .disconnected : (previous?.state ?? .disconnected))
            var runtime = previous ?? PairRuntimeStatus(pairID: pair.id)
            runtime.state = state
            return (pair.id, runtime)
        })
        lock.unlock()
        try migratePersistedCredentialsIfNeeded()
        appendLog("config.reload")
    }

    func shutdown() {
        lock.lock()
        _running = false
        lock.unlock()
        appendLog("daemon.shutdown")
    }

    func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _running
    }
}
