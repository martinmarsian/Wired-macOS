import Foundation
import Darwin
import SQLite3
import WiredSwift

/// Monotonically incremented whenever the daemon protocol or behaviour changes in a
/// way that requires the running process to be replaced after a client update.
/// Must be kept in sync with `WiredSyncDaemonIPC.expectedDaemonVersion` on the client.
private let kDaemonVersion = "8"

private enum SQLiteBindings {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

enum SyncMode: String, Codable {
    case serverToClient = "server_to_client"
    case clientToServer = "client_to_server"
    case bidirectional = "bidirectional"
}

struct SyncEndpoint: Codable {
    var serverURL: String
    var login: String
    var password: String
}

struct SyncPair: Codable {
    var id: String
    var remotePath: String
    var localPath: String
    var mode: SyncMode
    var deleteRemoteEnabled: Bool
    var endpoint: SyncEndpoint
    var paused: Bool
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case remotePath
        case localPath
        case mode
        case deleteRemoteEnabled
        case endpoint
        case paused
        case createdAt
        case updatedAt
    }

    enum LegacyCodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case login
        case password
    }

    init(
        id: String,
        remotePath: String,
        localPath: String,
        mode: SyncMode,
        deleteRemoteEnabled: Bool,
        endpoint: SyncEndpoint,
        paused: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.remotePath = remotePath
        self.localPath = localPath
        self.mode = mode
        self.deleteRemoteEnabled = deleteRemoteEnabled
        self.endpoint = endpoint
        self.paused = paused
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        remotePath = try c.decode(String.self, forKey: .remotePath)
        localPath = try c.decode(String.self, forKey: .localPath)
        mode = try c.decodeIfPresent(SyncMode.self, forKey: .mode) ?? .bidirectional
        deleteRemoteEnabled = try c.decodeIfPresent(Bool.self, forKey: .deleteRemoteEnabled) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

        if let endpoint = try c.decodeIfPresent(SyncEndpoint.self, forKey: .endpoint) {
            self.endpoint = endpoint
        } else {
            let lc = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let url = try lc.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
            let login = try lc.decodeIfPresent(String.self, forKey: .login) ?? ""
            let password = try lc.decodeIfPresent(String.self, forKey: .password) ?? ""
            self.endpoint = SyncEndpoint(serverURL: url, login: login, password: password)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(remotePath, forKey: .remotePath)
        try c.encode(localPath, forKey: .localPath)
        try c.encode(mode, forKey: .mode)
        try c.encode(deleteRemoteEnabled, forKey: .deleteRemoteEnabled)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(paused, forKey: .paused)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

struct DaemonConfig: Codable {
    var pairs: [SyncPair] = []
}

struct RPCRequest: Codable {
    var jsonrpc: String?
    var id: String?
    var method: String
    var params: [String: String]?
}

struct UploadedItemSnapshot {
    let relativePath: String
    let size: UInt64
    let modificationTime: TimeInterval
}

final class PathLayout {
    let baseDir: URL
    let configPath: URL
    let statePath: URL
    let runDir: URL
    let socketPath: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.baseDir = home.appendingPathComponent("Library/Application Support/WiredSync", isDirectory: true)
        self.configPath = baseDir.appendingPathComponent("config.json", isDirectory: false)
        self.statePath = baseDir.appendingPathComponent("state.sqlite", isDirectory: false)
        self.runDir = baseDir.appendingPathComponent("run", isDirectory: true)
        self.socketPath = runDir.appendingPathComponent("wiredsyncd.sock", isDirectory: false)
    }

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    }
}

final class SQLiteStore {
    private var db: OpaquePointer?

    init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw NSError(domain: "wiredsyncd", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open sqlite db"])
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS sync_pairs (
          id TEXT PRIMARY KEY,
          remote_path TEXT NOT NULL,
          local_path TEXT NOT NULL,
          mode TEXT NOT NULL,
          delete_remote_enabled INTEGER NOT NULL DEFAULT 0,
          endpoint_json TEXT NOT NULL,
          paused INTEGER NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS op_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          pair_id TEXT NOT NULL,
          op_kind TEXT NOT NULL,
          payload TEXT NOT NULL,
          created_at REAL NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS uploaded_items (
          pair_id TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          size INTEGER NOT NULL,
          modification_time REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY(pair_id, relative_path)
        );
        """)
        try execute("ALTER TABLE sync_pairs ADD COLUMN delete_remote_enabled INTEGER NOT NULL DEFAULT 0;")
        try execute("ALTER TABLE sync_pairs ADD COLUMN endpoint_json TEXT;")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func execute(_ sql: String) throws {
        guard let db else { return }
        var err: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            // Ignore duplicate-column migration attempt
            if msg.localizedCaseInsensitiveContains("duplicate column") {
                return
            }
            throw NSError(domain: "wiredsyncd", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    func upsert(pair: SyncPair) throws {
        guard let db else { return }
        let sql = """
        INSERT INTO sync_pairs(id, remote_path, local_path, mode, delete_remote_enabled, endpoint_json, paused, created_at, updated_at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          remote_path=excluded.remote_path,
          local_path=excluded.local_path,
          mode=excluded.mode,
          delete_remote_enabled=excluded.delete_remote_enabled,
          endpoint_json=excluded.endpoint_json,
          paused=excluded.paused,
          updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let endpointData = try JSONEncoder().encode(pair.endpoint)
        let endpointJSON = String(decoding: endpointData, as: UTF8.self)

        sqlite3_bind_text(stmt, 1, pair.id, -1, SQLiteBindings.transient)
        sqlite3_bind_text(stmt, 2, pair.remotePath, -1, SQLiteBindings.transient)
        sqlite3_bind_text(stmt, 3, pair.localPath, -1, SQLiteBindings.transient)
        sqlite3_bind_text(stmt, 4, pair.mode.rawValue, -1, SQLiteBindings.transient)
        sqlite3_bind_int(stmt, 5, pair.deleteRemoteEnabled ? 1 : 0)
        sqlite3_bind_text(stmt, 6, endpointJSON, -1, SQLiteBindings.transient)
        sqlite3_bind_int(stmt, 7, pair.paused ? 1 : 0)
        sqlite3_bind_double(stmt, 8, pair.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 9, pair.updatedAt.timeIntervalSince1970)

        _ = sqlite3_step(stmt)
    }

    func remove(id: String) throws {
        try execute("DELETE FROM sync_pairs WHERE id = '\(id.replacingOccurrences(of: "'", with: "''"))';")
        try execute("DELETE FROM uploaded_items WHERE pair_id = '\(id.replacingOccurrences(of: "'", with: "''"))';")
    }

    func enqueue(pairID: String, opKind: String, payload: String) throws {
        guard let db else { return }
        let sql = "INSERT INTO op_queue(pair_id, op_kind, payload, created_at) VALUES(?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)
        sqlite3_bind_text(stmt, 2, opKind, -1, SQLiteBindings.transient)
        sqlite3_bind_text(stmt, 3, payload, -1, SQLiteBindings.transient)
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }

    func queueDepth() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM op_queue;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func uploadedSnapshot(pairID: String, relativePath: String) -> UploadedItemSnapshot? {
        guard let db else { return nil }
        let sql = """
        SELECT relative_path, size, modification_time
        FROM uploaded_items
        WHERE pair_id = ? AND relative_path = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)
        sqlite3_bind_text(stmt, 2, relativePath, -1, SQLiteBindings.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let path = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? relativePath
        let size = UInt64(max(0, sqlite3_column_int64(stmt, 1)))
        let modificationTime = sqlite3_column_double(stmt, 2)
        return UploadedItemSnapshot(relativePath: path, size: size, modificationTime: modificationTime)
    }

    func markUploaded(pairID: String, relativePath: String, size: UInt64, modificationTime: TimeInterval) throws {
        guard let db else { return }
        let sql = """
        INSERT INTO uploaded_items(pair_id, relative_path, size, modification_time, updated_at)
        VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(pair_id, relative_path) DO UPDATE SET
          size=excluded.size,
          modification_time=excluded.modification_time,
          updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)
        sqlite3_bind_text(stmt, 2, relativePath, -1, SQLiteBindings.transient)
        sqlite3_bind_int64(stmt, 3, sqlite3_int64(size))
        sqlite3_bind_double(stmt, 4, modificationTime)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }

    func pruneUploadedSnapshots(pairID: String, keeping relativePaths: Set<String>) throws {
        guard let db else { return }
        let sql = "SELECT relative_path FROM uploaded_items WHERE pair_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)

        var stalePaths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            if !relativePaths.contains(path) {
                stalePaths.append(path)
            }
        }

        let deleteSQL = "DELETE FROM uploaded_items WHERE pair_id = ? AND relative_path = ?;"
        for stalePath in stalePaths {
            var deleteStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(deleteStmt, 1, pairID, -1, SQLiteBindings.transient)
            sqlite3_bind_text(deleteStmt, 2, stalePath, -1, SQLiteBindings.transient)
            _ = sqlite3_step(deleteStmt)
            sqlite3_finalize(deleteStmt)
        }
    }

    func clearUploadedSnapshots(pairID: String) throws {
        guard let db else { return }
        let sql = "DELETE FROM uploaded_items WHERE pair_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)
        _ = sqlite3_step(stmt)
    }

    func removeUploadedSnapshot(pairID: String, relativePath: String) throws {
        guard let db else { return }
        let sql = "DELETE FROM uploaded_items WHERE pair_id = ? AND relative_path = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)
        sqlite3_bind_text(stmt, 2, relativePath, -1, SQLiteBindings.transient)
        _ = sqlite3_step(stmt)
    }
}

final class DaemonState {
    let paths: PathLayout
    let store: SQLiteStore
    private var config: DaemonConfig
    private var _running: Bool = true
    private var logs: [String] = []
    private let lock = NSLock()

    init(paths: PathLayout, store: SQLiteStore) throws {
        self.paths = paths
        self.store = store
        self.config = try Self.loadConfig(path: paths.configPath)
        for pair in config.pairs {
            try store.upsert(pair: pair)
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

    func appendLog(_ line: String) {
        lock.lock()
        logs.append("\(ISO8601DateFormatter().string(from: Date())) \(line)")
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
        lock.unlock()
    }

    func tail(count: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(logs.suffix(max(0, count)))
    }

    func status(activePairs: Int) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return [
            "version": kDaemonVersion,
            "pairs_count": config.pairs.count,
            "active_pairs": activePairs,
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

    func addPair(
        remotePath: String,
        localPath: String,
        mode: SyncMode,
        deleteRemoteEnabled: Bool,
        endpoint: SyncEndpoint
    ) throws -> SyncPair {
        let now = Date()
        var pair = SyncPair(
            id: UUID().uuidString,
            remotePath: remotePath,
            localPath: localPath,
            mode: mode,
            deleteRemoteEnabled: deleteRemoteEnabled,
            endpoint: endpoint,
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
                let sameServer = item.endpoint.serverURL == endpoint.serverURL
                let sameLogin = item.endpoint.login == endpoint.login
                return (sameRemote && sameLocal && sameServer && sameLogin) ? index : nil
            }

            if let index = matchingIndexes.first {
                pair = config.pairs[index]
                let policyChanged = pair.mode != mode || pair.deleteRemoteEnabled != deleteRemoteEnabled
                pair.mode = mode
                pair.deleteRemoteEnabled = deleteRemoteEnabled
                pair.endpoint = endpoint
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
                try store.remove(id: staleID)
            }
        }
        try store.upsert(pair: pair)
        try store.enqueue(pairID: pair.id, opKind: "rescan", payload: "{}")
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
        try store.remove(id: id)
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
            try store.remove(id: removedID)
        }
        appendLog("pair.remove_by_remote remote=\(remotePath) count=\(removedIDs.count)")
        return removedIDs
    }

    func updatePairPolicy(
        remotePath: String,
        serverURL: String?,
        login: String?,
        mode: SyncMode,
        deleteRemoteEnabled: Bool
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
            guard pair.mode != mode || pair.deleteRemoteEnabled != deleteRemoteEnabled else { continue }
            config.pairs[index].mode = mode
            config.pairs[index].deleteRemoteEnabled = deleteRemoteEnabled
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
        appendLog("pair.\(paused ? "pause" : "resume") id=\(id)")
        return true
    }

    func reload() throws {
        let loaded = try Self.loadConfig(path: paths.configPath)
        lock.lock()
        config = loaded
        lock.unlock()
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

private struct LocalEntry {
    let relativePath: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
}

private struct RemoteEntry {
    let relativePath: String
    let absolutePath: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
}

private final class SyncPairWorker {
    private let pair: SyncPair
    private let store: SQLiteStore
    private let specPath: String
    private let log: (String) -> Void

    init(pair: SyncPair, store: SQLiteStore, specPath: String, log: @escaping (String) -> Void) {
        self.pair = pair
        self.store = store
        self.specPath = specPath
        self.log = log
    }

    private func withTimeout<T>(seconds: Double, label: String, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let ns = UInt64(max(0.1, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                throw NSError(
                    domain: "wiredsyncd.sync",
                    code: 901,
                    userInfo: [NSLocalizedDescriptionKey: "Timeout (\(Int(seconds))s) during \(label)"]
                )
            }
            guard let first = try await group.next() else {
                throw NSError(domain: "wiredsyncd.sync", code: 902, userInfo: [NSLocalizedDescriptionKey: "Timeout group failed for \(label)"])
            }
            group.cancelAll()
            return first
        }
    }

    func runOnce() async throws {
        var isDirectory: ObjCBool = false
        let localExists = FileManager.default.fileExists(atPath: pair.localPath, isDirectory: &isDirectory)
        if localExists && !isDirectory.boolValue {
            throw NSError(
                domain: "wiredsyncd.sync",
                code: 951,
                userInfo: [NSLocalizedDescriptionKey: "Local sync path is not a directory: \(pair.localPath)"]
            )
        }
        if !localExists {
            if pair.mode == .clientToServer {
                throw NSError(
                    domain: "wiredsyncd.sync",
                    code: 950,
                    userInfo: [NSLocalizedDescriptionKey: "Local sync path missing for client_to_server pair: \(pair.localPath)"]
                )
            }
            try FileManager.default.createDirectory(atPath: pair.localPath, withIntermediateDirectories: true)
            log("sync.local_recreated pair=\(pair.id) path=\(pair.localPath)")
        }
        log("sync.connect pair=\(pair.id) endpoint=\(pair.endpoint.serverURL)")

        let spec = P7Spec(withPath: specPath)
        let control = AsyncConnection(withSpec: spec)
        // AsyncConnection transaction streams require interactive listener mode.
        control.interactive = true

        let url = try makeURL(endpoint: pair.endpoint)
        try await withTimeout(seconds: 10, label: "connect") {
            try control.connect(withUrl: url)
        }
        log("sync.connected pair=\(pair.id)")
        defer { control.disconnect() }

        log("sync.list_remote pair=\(pair.id) path=\(pair.remotePath)")
        let remote: [String: RemoteEntry]
        var remoteInventoryAvailable = true
        do {
            remote = try await withTimeout(seconds: 20, label: "list_remote") {
                try await self.listRemoteTree(connection: control)
            }
            log("sync.list_remote_done pair=\(pair.id) items=\(remote.count)")
        } catch {
            if pair.mode == .clientToServer {
                // Write-only sync folders can legitimately deny list/read.
                // In that case we can still push local changes, but must not try remote pruning.
                remoteInventoryAvailable = false
                remote = [:]
                log("sync.list_remote_unavailable pair=\(pair.id) mode=client_to_server reason=\(error.localizedDescription)")
            } else {
                log("sync.list_remote_failed pair=\(pair.id) reason=\(error.localizedDescription)")
                throw NSError(
                    domain: "wiredsyncd.sync",
                    code: 903,
                    userInfo: [NSLocalizedDescriptionKey: "Remote listing failed; skipping sync cycle to avoid conflict amplification"]
                )
            }
        }

        log("sync.scan_local_start pair=\(pair.id) path=\(pair.localPath)")
        let local = try await withTimeout(seconds: 20, label: "scan_local") {
            try self.scanLocalTree()
        }
        log("sync.scan_local_done pair=\(pair.id) items=\(local.count)")

        log("sync.reconcile_start pair=\(pair.id) mode=\(pair.mode.rawValue)")
        switch pair.mode {
        case .serverToClient:
            try await withTimeout(seconds: 120, label: "reconcile_server_to_client") {
                try await self.reconcileServerToClient(control: control, spec: spec, remote: remote, local: local, url: url)
            }
        case .clientToServer:
            try await withTimeout(seconds: 120, label: "reconcile_client_to_server") {
                try await self.reconcileClientToServer(
                    control: control,
                    spec: spec,
                    remote: remote,
                    local: local,
                    url: url,
                    allowRemotePrune: remoteInventoryAvailable && self.pair.deleteRemoteEnabled
                )
            }
        case .bidirectional:
            try await withTimeout(seconds: 120, label: "reconcile_bidirectional") {
                try await self.reconcileBidirectional(control: control, spec: spec, remote: remote, local: local, url: url)
            }
        }
    }

    private func makeURL(endpoint: SyncEndpoint) throws -> Url {
        let trimmed = endpoint.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "wiredsyncd.sync", code: 100, userInfo: [NSLocalizedDescriptionKey: "Missing server URL"])
        }

        let normalized = trimmed.hasPrefix("wired://") ? trimmed : "wired://\(trimmed)"
        guard var components = URLComponents(string: normalized) else {
            throw NSError(domain: "wiredsyncd.sync", code: 101, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL"])
        }

        if !endpoint.login.isEmpty {
            components.user = endpoint.login
        }
        if !endpoint.password.isEmpty {
            components.password = endpoint.password
        }

        guard let final = components.string else {
            throw NSError(domain: "wiredsyncd.sync", code: 102, userInfo: [NSLocalizedDescriptionKey: "Invalid server URL components"])
        }
        return Url(withString: final)
    }

    private func listRemoteTree(connection: AsyncConnection) async throws -> [String: RemoteEntry] {
        var map: [String: RemoteEntry] = [:]
        var queue: [String] = [pair.remotePath]
        var visited: Set<String> = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if !visited.insert(current).inserted { continue }

            let message = P7Message(withName: "wired.file.list_directory", spec: connection.spec)
            message.addParameter(field: "wired.file.path", value: current)

            for try await response in try connection.sendAndWaitMany(message) {
                guard response.name == "wired.file.file_list" else { continue }

                let absolutePath = response.string(forField: "wired.file.path") ?? ""
                let relativePath = normalizedRelative(path: absolutePath, root: pair.remotePath)
                if relativePath.isEmpty { continue }
                if isConflictArtifact(relativePath: relativePath) { continue }

                let type = response.uint32(forField: "wired.file.type") ?? 0
                let isDirectory = type == 1 || type == 2 || type == 3 || type == 4
                let size = response.uint64(forField: "wired.file.data_size") ?? 0
                let modificationDate = response.date(forField: "wired.file.modification_time")

                map[relativePath] = RemoteEntry(
                    relativePath: relativePath,
                    absolutePath: absolutePath,
                    isDirectory: isDirectory,
                    size: size,
                    modificationDate: modificationDate
                )

                if isDirectory {
                    queue.append(absolutePath)
                }
            }
        }

        return map
    }

    private func scanLocalTree() throws -> [String: LocalEntry] {
        var map: [String: LocalEntry] = [:]
        let root = NSString(string: pair.localPath).standardizingPath

        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            return map
        }

        while let raw = enumerator.nextObject() as? String {
            let relativePath = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relativePath.isEmpty { continue }

            if containsHiddenPathComponent(relativePath) {
                enumerator.skipDescendants()
                continue
            }
            if isConflictArtifact(relativePath: relativePath) {
                continue
            }

            let absolutePath = (root as NSString).appendingPathComponent(relativePath)
            var st = stat()
            if lstat(absolutePath, &st) != 0 {
                continue
            }

            let mode = st.st_mode & S_IFMT
            let isDirectory = mode == S_IFDIR
            if !(isDirectory || mode == S_IFREG) {
                continue
            }

            let size = isDirectory ? UInt64(0) : UInt64(max(0, st.st_size))
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))

            map[relativePath] = LocalEntry(
                relativePath: relativePath,
                isDirectory: isDirectory,
                size: size,
                modificationDate: mtime
            )
        }

        return map
    }

    private func reconcileServerToClient(
        control: AsyncConnection,
        spec: P7Spec,
        remote: [String: RemoteEntry],
        local: [String: LocalEntry],
        url: Url
    ) async throws {
        let remoteDirs = remote.values.filter(\.isDirectory).map(\.relativePath).sorted()
        for rel in remoteDirs {
            try ensureLocalDirectory(relativePath: rel)
        }

        let remoteFiles = remote.values.filter { !$0.isDirectory }.sorted { $0.relativePath < $1.relativePath }
        for entry in remoteFiles {
            if shouldPull(remote: entry, local: local[entry.relativePath]) {
                try await downloadFile(
                    spec: spec,
                    url: url,
                    remoteAbsolutePath: entry.absolutePath,
                    localRelativePath: entry.relativePath,
                    remoteModificationDate: entry.modificationDate
                )
                try store.removeUploadedSnapshot(pairID: pair.id, relativePath: entry.relativePath)
                log("sync.pull pair=\(pair.id) path=\(entry.relativePath)")
            }
        }

        let remoteKeys = Set(remote.keys)
        let localKeys = Set(local.keys)
        let stale = localKeys.subtracting(remoteKeys).sorted { $0.count > $1.count }
        for rel in stale {
            try deleteLocal(relativePath: rel)
            try store.removeUploadedSnapshot(pairID: pair.id, relativePath: rel)
            log("sync.delete_local pair=\(pair.id) path=\(rel)")
        }
    }

    private func reconcileClientToServer(
        control: AsyncConnection,
        spec: P7Spec,
        remote: [String: RemoteEntry],
        local: [String: LocalEntry],
        url: Url,
        allowRemotePrune: Bool
    ) async throws {
        let localDirs = local.values.filter(\.isDirectory).map(\.relativePath).sorted()
        for rel in localDirs {
            try await ensureRemoteDirectory(connection: control, relativePath: rel)
        }

        let localFiles = local.values.filter { !$0.isDirectory }.sorted { $0.relativePath < $1.relativePath }
        for entry in localFiles {
            let shouldUpload: Bool
            if allowRemotePrune {
                shouldUpload = shouldPush(local: entry, remote: remote[entry.relativePath])
            } else {
                shouldUpload = shouldPushWithoutRemoteInventory(local: entry)
            }

            if shouldUpload {
                log("sync.push_try pair=\(pair.id) path=\(entry.relativePath)")
                try await uploadFile(spec: spec, url: url, localRelativePath: entry.relativePath, remoteRelativePath: entry.relativePath)
                try store.markUploaded(
                    pairID: pair.id,
                    relativePath: entry.relativePath,
                    size: entry.size,
                    modificationTime: entry.modificationDate?.timeIntervalSince1970 ?? 0
                )
                log("sync.push pair=\(pair.id) path=\(entry.relativePath)")
            }
        }

        if allowRemotePrune {
            let remoteKeys = Set(remote.keys)
            let localKeys = Set(local.keys)
            let stale = remoteKeys.subtracting(localKeys).sorted { $0.count > $1.count }
            for rel in stale {
                try await deleteRemote(connection: control, relativePath: rel)
                log("sync.delete_remote pair=\(pair.id) path=\(rel)")
            }
        } else {
            try store.pruneUploadedSnapshots(
                pairID: pair.id,
                keeping: Set(localFiles.map(\.relativePath))
            )
            log("sync.delete_remote_skipped pair=\(pair.id) reason=remote_inventory_unavailable")
        }
    }

    private func reconcileBidirectional(
        control: AsyncConnection,
        spec: P7Spec,
        remote: [String: RemoteEntry],
        local: [String: LocalEntry],
        url: Url
    ) async throws {
        let allKeys = Set(remote.keys).union(local.keys)

        for rel in allKeys.sorted() {
            let remoteEntry = remote[rel]
            let localEntry = local[rel]

            if let r = remoteEntry, r.isDirectory {
                try ensureLocalDirectory(relativePath: rel)
                continue
            }
            if let l = localEntry, l.isDirectory {
                try await ensureRemoteDirectory(connection: control, relativePath: rel)
                continue
            }

            switch (remoteEntry, localEntry) {
            case let (r?, nil):
                if !r.isDirectory {
                    try await downloadFile(
                        spec: spec,
                        url: url,
                        remoteAbsolutePath: r.absolutePath,
                        localRelativePath: rel,
                        remoteModificationDate: r.modificationDate
                    )
                    try store.removeUploadedSnapshot(pairID: pair.id, relativePath: rel)
                    log("sync.pull pair=\(pair.id) path=\(rel)")
                }

            case let (nil, l?):
                if !l.isDirectory {
                    log("sync.push_try pair=\(pair.id) path=\(rel)")
                    try await uploadFile(spec: spec, url: url, localRelativePath: rel, remoteRelativePath: rel)
                    try store.markUploaded(
                        pairID: pair.id,
                        relativePath: rel,
                        size: l.size,
                        modificationTime: l.modificationDate?.timeIntervalSince1970 ?? 0
                    )
                    log("sync.push pair=\(pair.id) path=\(rel)")
                }

            case let (r?, l?):
                guard !r.isDirectory && !l.isDirectory else { continue }
                let remoteDate = r.modificationDate
                let localDate = l.modificationDate
                let sizeDiffers = r.size != l.size
                let remoteTimestamp = remoteDate?.timeIntervalSince1970 ?? 0
                let localTimestamp = localDate?.timeIntervalSince1970 ?? 0
                let mtimeDiffers = abs(remoteTimestamp - localTimestamp) > 1.0

                if !sizeDiffers && !mtimeDiffers {
                    continue
                }

                if let remoteDate, let localDate {
                    let delta = remoteDate.timeIntervalSince(localDate)
                    if delta > 1.0 {
                        try await downloadFile(
                            spec: spec,
                            url: url,
                            remoteAbsolutePath: r.absolutePath,
                            localRelativePath: rel,
                            remoteModificationDate: r.modificationDate
                        )
                        try store.removeUploadedSnapshot(pairID: pair.id, relativePath: rel)
                        log("sync.pull pair=\(pair.id) path=\(rel)")
                    } else if delta < -1.0 {
                        try await uploadFile(spec: spec, url: url, localRelativePath: rel, remoteRelativePath: rel)
                        try store.markUploaded(
                            pairID: pair.id,
                            relativePath: rel,
                            size: l.size,
                            modificationTime: l.modificationDate?.timeIntervalSince1970 ?? 0
                        )
                        log("sync.push pair=\(pair.id) path=\(rel)")
                    } else {
                        // Avoid conflict amplification when mtimes are too close to compare reliably.
                        // Deterministic tie-break: local side wins.
                        try await uploadFile(spec: spec, url: url, localRelativePath: rel, remoteRelativePath: rel)
                        try store.markUploaded(
                            pairID: pair.id,
                            relativePath: rel,
                            size: l.size,
                            modificationTime: l.modificationDate?.timeIntervalSince1970 ?? 0
                        )
                        log("sync.push pair=\(pair.id) path=\(rel) reason=mtime_tie")
                    }
                } else if remoteDate != nil {
                    try await downloadFile(
                        spec: spec,
                        url: url,
                        remoteAbsolutePath: r.absolutePath,
                        localRelativePath: rel,
                        remoteModificationDate: r.modificationDate
                    )
                    try store.removeUploadedSnapshot(pairID: pair.id, relativePath: rel)
                    log("sync.pull pair=\(pair.id) path=\(rel) reason=remote_mtime_only")
                } else if localDate != nil {
                    try await uploadFile(spec: spec, url: url, localRelativePath: rel, remoteRelativePath: rel)
                    try store.markUploaded(
                        pairID: pair.id,
                        relativePath: rel,
                        size: l.size,
                        modificationTime: l.modificationDate?.timeIntervalSince1970 ?? 0
                    )
                    log("sync.push pair=\(pair.id) path=\(rel) reason=local_mtime_only")
                } else {
                    try await uploadFile(spec: spec, url: url, localRelativePath: rel, remoteRelativePath: rel)
                    try store.markUploaded(
                        pairID: pair.id,
                        relativePath: rel,
                        size: l.size,
                        modificationTime: l.modificationDate?.timeIntervalSince1970 ?? 0
                    )
                    log("sync.push pair=\(pair.id) path=\(rel) reason=no_mtime")
                }

            case (nil, nil):
                continue
            }
        }
    }

    private func resolveConflict(spec: P7Spec, url: Url, relativePath: String, remoteAbsolutePath: String) async throws {
        let localPath = localAbsolute(relativePath: relativePath)
        let localConflict = conflictPath(for: localPath)
        let remoteConflictRelative = conflictPath(for: relativePath)

        if FileManager.default.fileExists(atPath: localPath) {
            try FileManager.default.copyItem(atPath: localPath, toPath: localConflict)
        }

        try await downloadFile(
            spec: spec,
            url: url,
            remoteAbsolutePath: remoteAbsolutePath,
            localRelativePath: relativePath,
            remoteModificationDate: nil
        )
        if FileManager.default.fileExists(atPath: localConflict) {
            try await uploadFile(spec: spec, url: url, localRelativePath: normalizedRelative(path: localConflict, root: pair.localPath), remoteRelativePath: remoteConflictRelative)
        }

        log("sync.conflict pair=\(pair.id) path=\(relativePath)")
    }

    private func shouldPull(remote: RemoteEntry, local: LocalEntry?) -> Bool {
        guard let local else { return true }
        guard !local.isDirectory else { return true }
        if remote.size != local.size {
            return true
        }
        let remoteModificationTime = remote.modificationDate?.timeIntervalSince1970 ?? 0
        let localModificationTime = local.modificationDate?.timeIntervalSince1970 ?? 0
        return abs(remoteModificationTime - localModificationTime) > 1.0
    }

    private func shouldPush(local: LocalEntry, remote: RemoteEntry?) -> Bool {
        guard let remote else { return true }
        guard !remote.isDirectory else { return true }
        if local.size != remote.size {
            return true
        }
        if let snapshot = store.uploadedSnapshot(pairID: pair.id, relativePath: local.relativePath) {
            let localModificationTime = local.modificationDate?.timeIntervalSince1970 ?? 0
            if snapshot.size == local.size,
               abs(snapshot.modificationTime - localModificationTime) <= 1.0 {
                return false
            }
        }
        let localModificationTime = local.modificationDate?.timeIntervalSince1970 ?? 0
        let remoteModificationTime = remote.modificationDate?.timeIntervalSince1970 ?? 0
        return abs(localModificationTime - remoteModificationTime) > 1.0
    }

    private func shouldPushWithoutRemoteInventory(local: LocalEntry) -> Bool {
        guard let snapshot = store.uploadedSnapshot(pairID: pair.id, relativePath: local.relativePath) else {
            return true
        }
        let localModificationTime = local.modificationDate?.timeIntervalSince1970 ?? 0
        return snapshot.size != local.size || abs(snapshot.modificationTime - localModificationTime) > 1.0
    }

    private func ensureLocalDirectory(relativePath: String) throws {
        let absolute = localAbsolute(relativePath: relativePath)
        try FileManager.default.createDirectory(atPath: absolute, withIntermediateDirectories: true)
    }

    private func ensureRemoteDirectory(connection: AsyncConnection, relativePath: String) async throws {
        let absolutePath = remoteAbsolute(relativePath: relativePath)
        let message = P7Message(withName: "wired.transfer.upload_directory", spec: connection.spec)
        message.addParameter(field: "wired.file.path", value: absolutePath)
        do {
            _ = try await connection.sendAsync(message)
        } catch let AsyncConnectionError.serverError(message) {
            let code = message.enumeration(forField: "wired.error") ?? 0
            // wired.error.file_exists = 15
            if code != 15 {
                throw AsyncConnectionError.serverError(message)
            }
        }
    }

    private func deleteRemote(connection: AsyncConnection, relativePath: String) async throws {
        let message = P7Message(withName: "wired.file.delete", spec: connection.spec)
        message.addParameter(field: "wired.file.path", value: remoteAbsolute(relativePath: relativePath))
        _ = try await connection.sendAsync(message)
    }

    private func deleteLocal(relativePath: String) throws {
        let absolute = localAbsolute(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: absolute) else { return }
        try FileManager.default.removeItem(atPath: absolute)
    }

    private func downloadFile(
        spec: P7Spec,
        url: Url,
        remoteAbsolutePath: String,
        localRelativePath: String,
        remoteModificationDate: Date?
    ) async throws {
        let tconn = AsyncConnection(withSpec: spec)
        tconn.interactive = false
        try tconn.connect(withUrl: url)
        defer { tconn.disconnect() }

        let localPath = localAbsolute(relativePath: localRelativePath)
        let parent = (localPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let request = P7Message(withName: "wired.transfer.download_file", spec: spec)
        request.addParameter(field: "wired.file.path", value: remoteAbsolutePath)
        request.addParameter(field: "wired.transfer.data_offset", value: UInt64(0))
        request.addParameter(field: "wired.transfer.rsrc_offset", value: UInt64(0))

        guard tconn.send(message: request) else {
            throw NSError(domain: "wiredsyncd.sync", code: 200, userInfo: [NSLocalizedDescriptionKey: "Unable to request remote download"])
        }

        let runMessage = try waitForTransferMessage(connection: tconn, expected: "wired.transfer.download")
        let dataLength = runMessage.uint64(forField: "wired.transfer.data") ?? 0
        let rsrcLength = runMessage.uint64(forField: "wired.transfer.rsrc") ?? 0

        let tmpPath = "\(localPath).wiredsync.part"
        _ = FileManager.default.createFile(atPath: tmpPath, contents: Data())
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tmpPath))
        defer { try? handle.close() }

        var remainingData = dataLength
        while remainingData > 0 {
            let chunk = try tconn.socket.readOOB(timeout: 120)
            handle.write(chunk)
            remainingData = (remainingData > UInt64(chunk.count)) ? (remainingData - UInt64(chunk.count)) : 0
        }

        var remainingRsrc = rsrcLength
        while remainingRsrc > 0 {
            let chunk = try tconn.socket.readOOB(timeout: 120)
            remainingRsrc = (remainingRsrc > UInt64(chunk.count)) ? (remainingRsrc - UInt64(chunk.count)) : 0
        }

        if FileManager.default.fileExists(atPath: localPath) {
            try FileManager.default.removeItem(atPath: localPath)
        }
        try FileManager.default.moveItem(atPath: tmpPath, toPath: localPath)
        if let remoteModificationDate {
            try? FileManager.default.setAttributes([.modificationDate: remoteModificationDate], ofItemAtPath: localPath)
        }
    }

    private func uploadFile(spec: P7Spec, url: Url, localRelativePath: String, remoteRelativePath: String) async throws {
        let localPath = localAbsolute(relativePath: localRelativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: localPath)
        let expectedSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0

        let tconn = AsyncConnection(withSpec: spec)
        tconn.interactive = false
        try tconn.connect(withUrl: url)
        defer { tconn.disconnect() }

        let remoteAbsolutePath = remoteAbsolute(relativePath: remoteRelativePath)

        let uploadFile = P7Message(withName: "wired.transfer.upload_file", spec: spec)
        uploadFile.addParameter(field: "wired.file.path", value: remoteAbsolutePath)
        uploadFile.addParameter(field: "wired.transfer.data_size", value: expectedSize)
        uploadFile.addParameter(field: "wired.transfer.rsrc_size", value: UInt64(0))

        guard tconn.send(message: uploadFile) else {
            throw NSError(domain: "wiredsyncd.sync", code: 201, userInfo: [NSLocalizedDescriptionKey: "Unable to request remote upload"])
        }

        let ready = try waitForTransferMessage(connection: tconn, expected: "wired.transfer.upload_ready")
        let offset = ready.uint64(forField: "wired.transfer.data_offset") ?? 0

        let upload = P7Message(withName: "wired.transfer.upload", spec: spec)
        upload.addParameter(field: "wired.file.path", value: remoteAbsolutePath)
        upload.addParameter(field: "wired.transfer.data", value: expectedSize > offset ? expectedSize - offset : UInt64(0))
        upload.addParameter(field: "wired.transfer.rsrc", value: UInt64(0))
        upload.addParameter(field: "wired.transfer.finderinfo", value: Data(count: 32).base64EncodedData())

        guard tconn.send(message: upload) else {
            throw NSError(domain: "wiredsyncd.sync", code: 202, userInfo: [NSLocalizedDescriptionKey: "Unable to start remote upload"])
        }

        let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath))
        defer { try? fileHandle.close() }
        try fileHandle.seek(toOffset: offset)

        var remaining = expectedSize > offset ? expectedSize - offset : UInt64(0)
        while remaining > 0 {
            let chunk = try fileHandle.read(upToCount: min(65_536, Int(remaining))) ?? Data()
            if chunk.isEmpty {
                throw NSError(domain: "wiredsyncd.sync", code: 203, userInfo: [NSLocalizedDescriptionKey: "Unexpected EOF while uploading \(localPath)"])
            }
            try tconn.socket.writeOOB(data: chunk, timeout: 120)
            remaining -= UInt64(chunk.count)
        }
    }

    private func waitForTransferMessage(connection: AsyncConnection, expected: String) throws -> P7Message {
        while true {
            let message = try connection.readMessage()

            if message.name == expected {
                return message
            }

            if message.name == "wired.send_ping" || message.name == "wired.transfer.send_ping" {
                let reply = P7Message(withName: "wired.ping", spec: connection.spec)
                if let transaction = message.uint32(forField: "wired.transaction") {
                    reply.addParameter(field: "wired.transaction", value: transaction)
                }
                _ = connection.send(message: reply)
                continue
            }

            if message.name == "wired.transfer.queue" {
                continue
            }

            if message.name == "wired.error" {
                let code = message.enumeration(forField: "wired.error") ?? 0
                let text = message.string(forField: "wired.error.string") ?? "No error message"
                let detail = "wired.error(code=\(code), message=\(text), expected=\(expected))"
                throw NSError(domain: "wiredsyncd.sync", code: 204, userInfo: [NSLocalizedDescriptionKey: detail])
            }
        }
    }

    private func localAbsolute(relativePath: String) -> String {
        (pair.localPath as NSString).appendingPathComponent(relativePath)
    }

    private func remoteAbsolute(relativePath: String) -> String {
        normalizedJoin(base: pair.remotePath, relative: relativePath)
    }

    private func normalizedRelative(path: String, root: String) -> String {
        let p = NSString(string: path).standardizingPath
        let r = NSString(string: root).standardizingPath
        if p == r { return "" }
        guard p.hasPrefix(r) else { return p.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        var rel = String(p.dropFirst(r.count))
        while rel.hasPrefix("/") {
            rel.removeFirst()
        }
        return rel
    }

    private func normalizedJoin(base: String, relative: String) -> String {
        if relative.isEmpty { return base }
        if base == "/" {
            return "/\(relative)"
        }
        return (base as NSString).appendingPathComponent(relative)
    }

    private func containsHiddenPathComponent(_ relativePath: String) -> Bool {
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            if component.hasPrefix(".") {
                return true
            }
        }
        return false
    }

    private func isConflictArtifact(relativePath: String) -> Bool {
        let fileName = (relativePath as NSString).lastPathComponent.lowercased()
        return fileName.contains(".conflict.")
    }

    private func conflictPath(for path: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let username = pair.endpoint.login.isEmpty ? "user" : pair.endpoint.login
        let base = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        if ext.isEmpty {
            return "\(base).conflict.\(username).\(timestamp)"
        }
        return "\(base).conflict.\(username).\(timestamp).\(ext)"
    }
}

private final class SyncEngine {
    private let state: DaemonState
    private let specPath: String
    private let lock = NSLock()
    private var activePairs: Set<String> = []
    private var loopTask: Task<Void, Never>?

    init(state: DaemonState, specPath: String) {
        self.state = state
        self.specPath = specPath
    }

    func start() {
        loopTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            while self.state.isRunning() {
                await self.tick()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activePairs.count
    }

    func triggerNow(remotePath: String?, serverURL: String?, login: String?) -> (matched: Int, launched: Int) {
        let normalizedServer = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs = state.snapshotPairs().filter { pair in
            guard !pair.paused else { return false }
            guard let remotePath else { return true }
            guard pair.remotePath == remotePath else { return false }
            if let normalizedServer, !normalizedServer.isEmpty, pair.endpoint.serverURL != normalizedServer {
                return false
            }
            if let normalizedLogin, !normalizedLogin.isEmpty, pair.endpoint.login != normalizedLogin {
                return false
            }
            return true
        }

        var launched = 0
        for pair in pairs {
            guard startPair(id: pair.id) else { continue }
            launched += 1
            runPair(pair)
        }
        return (pairs.count, launched)
    }

    private func startPair(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if activePairs.contains(id) {
            return false
        }
        activePairs.insert(id)
        return true
    }

    private func finishPair(id: String) {
        lock.lock()
        activePairs.remove(id)
        lock.unlock()
    }

    private func runPair(_ pair: SyncPair) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.finishPair(id: pair.id) }
            do {
                self.state.appendLog("sync.start pair=\(pair.id) mode=\(pair.mode.rawValue)")
                let worker = SyncPairWorker(pair: pair, store: self.state.store, specPath: self.specPath) { line in
                    self.state.appendLog(line)
                }
                try await worker.runOnce()
                self.state.appendLog("sync.done pair=\(pair.id)")
            } catch {
                let nsError = error as NSError
                if nsError.domain == "wiredsyncd.sync", nsError.code == 950 {
                    if (try? self.state.setPaused(id: pair.id, paused: true)) == true {
                        self.state.appendLog("pair.paused id=\(pair.id) reason=local_path_missing_client_to_server")
                    }
                }
                self.state.appendLog("sync.error pair=\(pair.id) error=\(describeSyncError(error))")
            }
        }
    }

    private func tick() async {
        let pairs = state.snapshotPairs().filter { !$0.paused }
        for pair in pairs {
            guard startPair(id: pair.id) else { continue }
            runPair(pair)
        }
    }
}

private func describeSyncError(_ error: Error) -> String {
    if let wired = error as? WiredError {
        return wired.description
    }
    if let asyncError = error as? AsyncConnectionError {
        switch asyncError {
        case .notConnected:
            return "AsyncConnectionError.notConnected"
        case .writeFailed:
            return "AsyncConnectionError.writeFailed"
        case .serverError(let message):
            let code = message.enumeration(forField: "wired.error") ?? 0
            let text = message.string(forField: "wired.error.string") ?? "No server message"
            return "AsyncConnectionError.serverError(code=\(code), message=\(text))"
        }
    }
    return String(describing: error)
}

private func setSocketPermissions(path: String) {
    chmod(path, mode_t(S_IRUSR | S_IWUSR))
}

private func setClientReadTimeout(fd: Int32, seconds: Int) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    withUnsafePointer(to: &timeout) { ptr in
        ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { raw in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, raw, socklen_t(MemoryLayout<timeval>.size))
        }
    }
}

private func verifyPeerUID(_ clientFD: Int32) -> Bool {
    var uid = uid_t()
    var gid = gid_t()
    if getpeereid(clientFD, &uid, &gid) != 0 {
        return false
    }
    return uid == geteuid()
}

private func socketAddr(path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    let bytes = Array(path.utf8.prefix(maxLen - 1))
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
        raw.initialize(repeating: 0, count: maxLen)
        for (i, b) in bytes.enumerated() {
            raw[i] = CChar(bitPattern: b)
        }
    }
    return addr
}

private func sendJSON(_ object: Any, to fd: Int32) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
        return
    }
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        _ = Darwin.write(fd, base, data.count)
        _ = Darwin.write(fd, "\n", 1)
    }
}

private func readLine(from fd: Int32) -> String? {
    var buffer = [UInt8](repeating: 0, count: 16384)
    let n = Darwin.read(fd, &buffer, buffer.count)
    guard n > 0 else { return nil }
    return String(decoding: buffer[0..<n], as: UTF8.self)
}

private func decodeRequest(_ text: String) -> RPCRequest? {
    guard let data = text.data(using: .utf8) else { return nil }
    if let request = try? JSONDecoder().decode(RPCRequest.self, from: data) {
        return request
    }
    if let first = text.split(separator: "\n").first,
       let data = first.data(using: .utf8),
       let request = try? JSONDecoder().decode(RPCRequest.self, from: data) {
        return request
    }
    return nil
}

private func respondError(id: String?, code: Int, message: String, fd: Int32) {
    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id as Any,
        "error": ["code": code, "message": message]
    ]
    sendJSON(payload, to: fd)
}

private func respondResult(id: String?, result: [String: Any], fd: Int32) {
    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": id as Any,
        "result": result
    ]
    sendJSON(payload, to: fd)
}

private func handleRequest(_ req: RPCRequest, state: DaemonState, engine: SyncEngine, fd: Int32) {
    let params = req.params ?? [:]
    switch req.method {
    case "status":
        respondResult(id: req.id, result: state.status(activePairs: engine.activeCount()), fd: fd)

    case "list_pairs":
        let rows = state.snapshotPairs().map { pair in
            [
                "id": pair.id,
                "remote_path": pair.remotePath,
                "local_path": pair.localPath,
                "mode": pair.mode.rawValue,
                "delete_remote_enabled": pair.deleteRemoteEnabled ? "true" : "false",
                "server_url": pair.endpoint.serverURL,
                "login": pair.endpoint.login,
                "paused": pair.paused ? "true" : "false"
            ]
        }
        respondResult(id: req.id, result: ["ok": true, "pairs": rows], fd: fd)

    case "add_pair":
        guard let remotePath = params["remote_path"],
              let localPath = params["local_path"] else {
            respondError(id: req.id, code: -32602, message: "remote_path/local_path required", fd: fd)
            return
        }
        let mode = SyncMode(rawValue: params["mode"] ?? "bidirectional") ?? .bidirectional
        let deleteRemoteEnabledRaw = (params["delete_remote_enabled"] ?? "false").lowercased()
        let deleteRemoteEnabled = deleteRemoteEnabledRaw == "true" || deleteRemoteEnabledRaw == "1"
        let endpoint = SyncEndpoint(
            serverURL: params["server_url"] ?? "",
            login: params["login"] ?? "",
            password: params["password"] ?? ""
        )
        guard !endpoint.serverURL.isEmpty else {
            respondError(id: req.id, code: -32602, message: "server_url required for standalone daemon", fd: fd)
            return
        }

        do {
            let pair = try state.addPair(
                remotePath: remotePath,
                localPath: localPath,
                mode: mode,
                deleteRemoteEnabled: deleteRemoteEnabled,
                endpoint: endpoint
            )
            respondResult(id: req.id, result: ["ok": true, "pair_id": pair.id], fd: fd)
        } catch {
            respondError(id: req.id, code: -32000, message: "add_pair failed: \(error.localizedDescription)", fd: fd)
        }

    case "remove_pair":
        guard let pairID = params["pair_id"] else {
            respondError(id: req.id, code: -32602, message: "pair_id required", fd: fd)
            return
        }
        do {
            let ok = try state.removePair(id: pairID)
            respondResult(id: req.id, result: ["ok": ok], fd: fd)
        } catch {
            respondError(id: req.id, code: -32000, message: "remove_pair failed: \(error.localizedDescription)", fd: fd)
        }

    case "remove_pair_for_remote":
        guard let remotePath = params["remote_path"] else {
            respondError(id: req.id, code: -32602, message: "remote_path required", fd: fd)
            return
        }
        do {
            let removed = try state.removePairs(remotePath: remotePath, serverURL: params["server_url"], login: params["login"])
            respondResult(
                id: req.id,
                result: [
                    "ok": true,
                    "removed_count": removed.count,
                    "removed_ids": removed
                ],
                fd: fd
            )
        } catch {
            respondError(id: req.id, code: -32000, message: "remove_pair_for_remote failed: \(error.localizedDescription)", fd: fd)
        }

    case "rename_pair_remote":
        guard let oldPath = params["old_remote_path"],
              let newPath = params["new_remote_path"] else {
            respondError(id: req.id, code: -32602, message: "old_remote_path/new_remote_path required", fd: fd)
            return
        }
        do {
            let updated = try state.renamePairRemotePath(
                oldPath: oldPath,
                newPath: newPath,
                serverURL: params["server_url"],
                login: params["login"]
            )
            respondResult(
                id: req.id,
                result: [
                    "ok": true,
                    "updated_count": updated.count,
                    "updated_ids": updated
                ],
                fd: fd
            )
        } catch {
            respondError(id: req.id, code: -32000, message: "rename_pair_remote failed: \(error.localizedDescription)", fd: fd)
        }

    case "update_pair_policy", "update_pair_mode":
        guard let remotePath = params["remote_path"] else {
            respondError(id: req.id, code: -32602, message: "remote_path required", fd: fd)
            return
        }
        guard let modeRaw = params["mode"],
              let mode = SyncMode(rawValue: modeRaw) else {
            respondError(id: req.id, code: -32602, message: "valid mode required", fd: fd)
            return
        }
        let deleteRemoteEnabledRaw = (params["delete_remote_enabled"] ?? "false").lowercased()
        let deleteRemoteEnabled = deleteRemoteEnabledRaw == "true" || deleteRemoteEnabledRaw == "1"
        do {
            let updated = try state.updatePairPolicy(
                remotePath: remotePath,
                serverURL: params["server_url"],
                login: params["login"],
                mode: mode,
                deleteRemoteEnabled: deleteRemoteEnabled
            )
            respondResult(
                id: req.id,
                result: [
                    "ok": true,
                    "updated_count": updated.count,
                    "updated_ids": updated
                ],
                fd: fd
            )
        } catch {
            respondError(id: req.id, code: -32000, message: "\(req.method) failed: \(error.localizedDescription)", fd: fd)
        }

    case "pause_pair":
        guard let pairID = params["pair_id"] else {
            respondError(id: req.id, code: -32602, message: "pair_id required", fd: fd)
            return
        }
        do {
            let ok = try state.setPaused(id: pairID, paused: true)
            respondResult(id: req.id, result: ["ok": ok], fd: fd)
        } catch {
            respondError(id: req.id, code: -32000, message: "pause_pair failed: \(error.localizedDescription)", fd: fd)
        }

    case "resume_pair":
        guard let pairID = params["pair_id"] else {
            respondError(id: req.id, code: -32602, message: "pair_id required", fd: fd)
            return
        }
        do {
            let ok = try state.setPaused(id: pairID, paused: false)
            respondResult(id: req.id, result: ["ok": ok], fd: fd)
        } catch {
            respondError(id: req.id, code: -32000, message: "resume_pair failed: \(error.localizedDescription)", fd: fd)
        }

    case "reload":
        do {
            try state.reload()
            respondResult(id: req.id, result: ["ok": true], fd: fd)
        } catch {
            respondError(id: req.id, code: -32000, message: "reload failed: \(error.localizedDescription)", fd: fd)
        }

    case "sync_now":
        let remotePath = params["remote_path"]
        let result = engine.triggerNow(remotePath: remotePath, serverURL: params["server_url"], login: params["login"])
        if result.matched == 0 {
            respondError(
                id: req.id,
                code: -32004,
                message: "sync_now failed: no active pair found for remote_path \(remotePath ?? "*") server_url \(params["server_url"] ?? "*") login \(params["login"] ?? "*")",
                fd: fd
            )
            return
        }
        state.appendLog("sync.now remote=\(remotePath ?? "*") matched=\(result.matched) launched=\(result.launched)")
        respondResult(
            id: req.id,
            result: [
                "ok": true,
                "matched": result.matched,
                "launched": result.launched
            ],
            fd: fd
        )

    case "logs_tail":
        let count = Int(params["count"] ?? "50") ?? 50
        let tail = state.tail(count: count)
        respondResult(id: req.id, result: ["ok": true, "lines": tail], fd: fd)

    case "shutdown":
        state.shutdown()
        engine.stop()
        respondResult(id: req.id, result: ["ok": true], fd: fd)

    default:
        respondError(id: req.id, code: -32601, message: "method not found", fd: fd)
    }
}

private func resolveEmbeddedSpecURL(paths: PathLayout) throws -> URL {
    let fm = FileManager.default
    let env = ProcessInfo.processInfo.environment
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let executableDir = executableURL.deletingLastPathComponent()

    let candidates: [URL?] = [
        env["WIRED_SYNCD_RESOURCE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("wired.xml", isDirectory: false) },
        Bundle.module.url(forResource: "wired", withExtension: "xml"),
        Bundle.module.url(forResource: "wired", withExtension: "xml", subdirectory: "Resources"),
        Bundle.main.resourceURL?.appendingPathComponent("wired.xml", isDirectory: false),
        executableDir.appendingPathComponent("Resources/wired.xml", isDirectory: false),
        executableDir.appendingPathComponent("wired.xml", isDirectory: false),
        paths.baseDir.appendingPathComponent("daemon/Resources/wired.xml", isDirectory: false)
    ]

    for candidate in candidates.compactMap({ $0 }) {
        if fm.fileExists(atPath: candidate.path) {
            return candidate
        }
    }

    throw NSError(domain: "wiredsyncd", code: 21, userInfo: [NSLocalizedDescriptionKey: "Missing embedded wired.xml resource"])
}

private func runServer() throws {
    let paths = PathLayout()
    try paths.ensureDirectories()
    unlink(paths.socketPath.path)

    let store = try SQLiteStore(path: paths.statePath.path)
    let state = try DaemonState(paths: paths, store: store)

    let specURL = try resolveEmbeddedSpecURL(paths: paths)

    let engine = SyncEngine(state: state, specPath: specURL.path)
    engine.start()

    let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
        throw NSError(domain: "wiredsyncd", code: 10, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
    }
    defer { close(serverFD) }

    var addr = socketAddr(path: paths.socketPath.path)
    let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout.size(ofValue: addr.sun_path))
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(serverFD, $0, addrLen)
        }
    }
    guard bindResult == 0 else {
        throw NSError(domain: "wiredsyncd", code: 11, userInfo: [NSLocalizedDescriptionKey: "bind() failed"])
    }

    setSocketPermissions(path: paths.socketPath.path)

    guard listen(serverFD, 16) == 0 else {
        throw NSError(domain: "wiredsyncd", code: 12, userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
    }

    state.appendLog("daemon.start socket=\(paths.socketPath.path)")

    while state.isRunning() {
        var clientAddr = sockaddr()
        var clientLen: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
        let clientFD = accept(serverFD, &clientAddr, &clientLen)
        if clientFD < 0 {
            usleep(20_000)
            continue
        }

        if !verifyPeerUID(clientFD) {
            respondError(id: nil, code: -32001, message: "permission denied (uid mismatch)", fd: clientFD)
            close(clientFD)
            continue
        }

        setClientReadTimeout(fd: clientFD, seconds: 5)

        guard let line = readLine(from: clientFD), let req = decodeRequest(line) else {
            respondError(id: nil, code: -32700, message: "invalid json", fd: clientFD)
            close(clientFD)
            continue
        }

        handleRequest(req, state: state, engine: engine, fd: clientFD)
        close(clientFD)
    }

    engine.stop()
    unlink(paths.socketPath.path)
}

@main
struct WiredSyncDaemonMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            try runServer()
        } catch {
            fputs("wiredsyncd: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
