import Foundation
import Darwin
import AppKit
import Network
import SQLite3
import Security
import WiredSwift

/// Monotonically incremented whenever the daemon protocol or behaviour changes in a
/// way that requires the running process to be replaced after a client update.
/// Must be kept in sync with `WiredSyncDaemonIPC.expectedDaemonVersion` on the client.
private let kDaemonVersion = "28"
private let kDaemonNick = "wiredsyncd"

private enum SQLiteBindings {
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private final class DaemonClientInfoDelegate: ClientInfoDelegate {
    private let applicationInfo = WiredApplicationInfo.current().overriding(name: "wiredsyncd")

    func clientInfoApplicationName(for connection: Connection) -> String? {
        applicationInfo.name
    }

    func clientInfoApplicationVersion(for connection: Connection) -> String? {
        applicationInfo.version
    }

    func clientInfoApplicationBuild(for connection: Connection) -> String? {
        applicationInfo.build
    }
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

    enum CodingKeys: String, CodingKey {
        case serverURL
        case login
    }

    enum LegacyCodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case login
        case password
    }

    init(serverURL: String, login: String, password: String) {
        self.serverURL = serverURL
        self.login = login
        self.password = password
    }

    init(from decoder: Decoder) throws {
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           c.contains(.serverURL) || c.contains(.login) {
            let lc = try decoder.container(keyedBy: LegacyCodingKeys.self)
            serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL)
                ?? lc.decodeIfPresent(String.self, forKey: .serverURL)
                ?? ""
            login = try c.decodeIfPresent(String.self, forKey: .login)
                ?? lc.decodeIfPresent(String.self, forKey: .login)
                ?? ""
            password = try lc.decodeIfPresent(String.self, forKey: .password) ?? ""
            return
        }

        let lc = try decoder.container(keyedBy: LegacyCodingKeys.self)
        serverURL = try lc.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
        login = try lc.decodeIfPresent(String.self, forKey: .login) ?? ""
        password = try lc.decodeIfPresent(String.self, forKey: .password) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(serverURL, forKey: .serverURL)
        try c.encode(login, forKey: .login)
    }
}

struct SyncPair: Codable {
    var id: String
    var remotePath: String
    var localPath: String
    var mode: SyncMode
    var deleteRemoteEnabled: Bool
    /// Newline-separated glob patterns for files to exclude from sync.
    var excludePatterns: [String]
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
        case excludePatterns
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
        excludePatterns: [String] = [],
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
        self.excludePatterns = excludePatterns
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
        excludePatterns = try c.decodeIfPresent([String].self, forKey: .excludePatterns) ?? []
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
        try c.encode(excludePatterns, forKey: .excludePatterns)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(paused, forKey: .paused)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

enum PairConnectionState: String {
    case disconnected
    case connecting
    case connected
    case syncing
    case reconnecting
    case error
    case paused
}

struct PairRuntimeStatus {
    let pairID: String
    var state: PairConnectionState
    var lastError: String?
    var retryCount: Int
    var nextRetryAt: Date?
    var lastConnectedAt: Date?
    var lastSyncStartedAt: Date?
    var lastSyncCompletedAt: Date?
    var remoteInventoryAvailable: Bool?

    init(
        pairID: String,
        state: PairConnectionState = .disconnected,
        lastError: String? = nil,
        retryCount: Int = 0,
        nextRetryAt: Date? = nil,
        lastConnectedAt: Date? = nil,
        lastSyncStartedAt: Date? = nil,
        lastSyncCompletedAt: Date? = nil,
        remoteInventoryAvailable: Bool? = nil
    ) {
        self.pairID = pairID
        self.state = state
        self.lastError = lastError
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.lastConnectedAt = lastConnectedAt
        self.lastSyncStartedAt = lastSyncStartedAt
        self.lastSyncCompletedAt = lastSyncCompletedAt
        self.remoteInventoryAvailable = remoteInventoryAvailable
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
    static let appSupportDirEnv = "WIREDSYNCD_APP_SUPPORT_DIR"
    static let runDirEnv = "WIREDSYNCD_RUN_DIR"

    let baseDir: URL
    let configPath: URL
    let statePath: URL
    let runDir: URL
    let socketPath: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultBaseDir = home.appendingPathComponent("Library/Application Support/WiredSync", isDirectory: true)
        self.baseDir = environment[Self.appSupportDirEnv].map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        } ?? defaultBaseDir
        self.configPath = baseDir.appendingPathComponent("config.json", isDirectory: false)
        self.statePath = baseDir.appendingPathComponent("state.sqlite", isDirectory: false)
        self.runDir = environment[Self.runDirEnv].map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        } ?? baseDir.appendingPathComponent("run", isDirectory: true)
        self.socketPath = runDir.appendingPathComponent("wiredsyncd.sock", isDirectory: false)
    }

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
    }
}

final class SQLiteStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "fr.read-write.wiredsyncd.sqlite")

    init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw NSError(domain: "wiredsyncd", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to open sqlite db"])
        }
        try configureDatabase()
        try execute("""
        CREATE TABLE IF NOT EXISTS sync_pairs (
          id TEXT PRIMARY KEY,
          remote_path TEXT NOT NULL,
          local_path TEXT NOT NULL,
          mode TEXT NOT NULL,
          delete_remote_enabled INTEGER NOT NULL DEFAULT 0,
          exclude_patterns TEXT NOT NULL DEFAULT '',
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
        try execute("ALTER TABLE sync_pairs ADD COLUMN exclude_patterns TEXT NOT NULL DEFAULT '';")
        try execute("ALTER TABLE sync_pairs ADD COLUMN endpoint_json TEXT;")
    }

    deinit {
        let handle = queue.sync { db }
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        try queue.sync {
            guard let db else { return }
            var err: UnsafeMutablePointer<Int8>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? sqliteMessage(db)
                sqlite3_free(err)
                // Ignore duplicate-column migration attempt
                if msg.localizedCaseInsensitiveContains("duplicate column") {
                    return
                }
                throw NSError(domain: "wiredsyncd", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
    }

    func upsert(pair: SyncPair) throws {
        let endpointData = try JSONEncoder().encode(pair.endpoint)
        let endpointJSON = String(decoding: endpointData, as: UTF8.self)
        let excludePatternsJSON = pair.excludePatterns.joined(separator: "\n")

        try queue.sync {
            guard let db else { return }
            let sql = """
            INSERT INTO sync_pairs(id, remote_path, local_path, mode, delete_remote_enabled, exclude_patterns, endpoint_json, paused, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              remote_path=excluded.remote_path,
              local_path=excluded.local_path,
              mode=excluded.mode,
              delete_remote_enabled=excluded.delete_remote_enabled,
              exclude_patterns=excluded.exclude_patterns,
              endpoint_json=excluded.endpoint_json,
              paused=excluded.paused,
              updated_at=excluded.updated_at;
            """
            var stmt: OpaquePointer?
            try prepare(db, sql: sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, pair.id, -1, SQLiteBindings.transient)
            sqlite3_bind_text(stmt, 2, pair.remotePath, -1, SQLiteBindings.transient)
            sqlite3_bind_text(stmt, 3, pair.localPath, -1, SQLiteBindings.transient)
            sqlite3_bind_text(stmt, 4, pair.mode.rawValue, -1, SQLiteBindings.transient)
            sqlite3_bind_int(stmt, 5, pair.deleteRemoteEnabled ? 1 : 0)
            sqlite3_bind_text(stmt, 6, excludePatternsJSON, -1, SQLiteBindings.transient)
            sqlite3_bind_text(stmt, 7, endpointJSON, -1, SQLiteBindings.transient)
            sqlite3_bind_int(stmt, 8, pair.paused ? 1 : 0)
            sqlite3_bind_double(stmt, 9, pair.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 10, pair.updatedAt.timeIntervalSince1970)

            try stepDone(db, stmt: stmt)
        }
    }

    func remove(id: String) throws {
        try execute("DELETE FROM sync_pairs WHERE id = '\(id.replacingOccurrences(of: "'", with: "''"))';")
        try execute("DELETE FROM uploaded_items WHERE pair_id = '\(id.replacingOccurrences(of: "'", with: "''"))';")
    }

    func enqueue(pairID: String, opKind: String, payload: String) throws {
        try queue.sync {
            guard let db else { return }
            let sql = "INSERT INTO op_queue(pair_id, op_kind, payload, created_at) VALUES(?, ?, ?, ?);"
            var stmt: OpaquePointer?
            try prepare(db, sql: sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)
            sqlite3_bind_text(stmt, 2, opKind, -1, SQLiteBindings.transient)
            sqlite3_bind_text(stmt, 3, payload, -1, SQLiteBindings.transient)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
            try stepDone(db, stmt: stmt)
        }
    }

    func queueDepth() -> Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM op_queue;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    func uploadedSnapshot(pairID: String, relativePath: String) -> UploadedItemSnapshot? {
        queue.sync {
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
    }

    func markUploaded(pairID: String, relativePath: String, size: UInt64, modificationTime: TimeInterval) throws {
        try queue.sync {
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
            try prepare(db, sql: sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)
            sqlite3_bind_text(stmt, 2, relativePath, -1, SQLiteBindings.transient)
            sqlite3_bind_int64(stmt, 3, sqlite3_int64(size))
            sqlite3_bind_double(stmt, 4, modificationTime)
            sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
            try stepDone(db, stmt: stmt)
        }
    }

    func pruneUploadedSnapshots(pairID: String, keeping relativePaths: Set<String>) throws {
        try queue.sync {
            guard let db else { return }
            let sql = "SELECT relative_path FROM uploaded_items WHERE pair_id = ?;"
            var stmt: OpaquePointer?
            try prepare(db, sql: sql, into: &stmt)
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
                try prepare(db, sql: deleteSQL, into: &deleteStmt)
                sqlite3_bind_text(deleteStmt, 1, pairID, -1, SQLiteBindings.transient)
                sqlite3_bind_text(deleteStmt, 2, stalePath, -1, SQLiteBindings.transient)
                try stepDone(db, stmt: deleteStmt)
                sqlite3_finalize(deleteStmt)
            }
        }
    }

    func clearUploadedSnapshots(pairID: String) throws {
        try queue.sync {
            guard let db else { return }
            let sql = "DELETE FROM uploaded_items WHERE pair_id = ?;"
            var stmt: OpaquePointer?
            try prepare(db, sql: sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)
            try stepDone(db, stmt: stmt)
        }
    }

    func removeUploadedSnapshot(pairID: String, relativePath: String) throws {
        try queue.sync {
            guard let db else { return }
            let sql = "DELETE FROM uploaded_items WHERE pair_id = ? AND relative_path = ?;"
            var stmt: OpaquePointer?
            try prepare(db, sql: sql, into: &stmt)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, pairID, -1, SQLiteBindings.transient)
            sqlite3_bind_text(stmt, 2, relativePath, -1, SQLiteBindings.transient)
            try stepDone(db, stmt: stmt)
        }
    }

    private func configureDatabase() throws {
        guard let db else { return }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    private func prepare(_ db: OpaquePointer, sql: String, into stmt: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(domain: "wiredsyncd", code: 3, userInfo: [NSLocalizedDescriptionKey: sqliteMessage(db)])
        }
    }

    private func stepDone(_ db: OpaquePointer, stmt: OpaquePointer?) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "wiredsyncd", code: 4, userInfo: [NSLocalizedDescriptionKey: sqliteMessage(db)])
        }
    }

    private func sqliteMessage(_ db: OpaquePointer) -> String {
        sqlite3_errmsg(db).map { String(cString: $0) } ?? "sqlite error"
    }
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

final class DaemonState {
    let paths: PathLayout
    let store: SQLiteStore
    let secrets: KeychainSecretStore
    private var config: DaemonConfig
    private var _running: Bool = true
    private var logs: [String] = []
    private var runtimeStatuses: [String: PairRuntimeStatus] = [:]
    private let lock = NSLock()

    init(paths: PathLayout, store: SQLiteStore, secrets: KeychainSecretStore = .shared) throws {
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

func syncPathContainsHiddenPathComponent(_ relativePath: String) -> Bool {
    for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
        if component.hasPrefix(".") {
            return true
        }
    }
    return false
}

func syncPathIsConflictArtifact(_ relativePath: String) -> Bool {
    let fileName = (relativePath as NSString).lastPathComponent.lowercased()
    return fileName.contains(".conflict.")
}

func syncPathIsTransientTransferArtifact(_ relativePath: String) -> Bool {
    let fileName = (relativePath as NSString).lastPathComponent.lowercased()
    return fileName.hasSuffix(".wiredtransfer") || fileName.hasSuffix(".wiredsync.part")
}

func syncPathIsExcluded(_ relativePath: String, excludePatterns: [String]) -> Bool {
    guard !excludePatterns.isEmpty else { return false }
    let fileName = (relativePath as NSString).lastPathComponent
    for pattern in excludePatterns {
        let pat = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pat.isEmpty, !pat.hasPrefix("#") else { continue }
        if pat.contains("/") {
            if fnmatch(pat, relativePath, FNM_PATHNAME) == 0 { return true }
        } else {
            if fnmatch(pat, fileName, 0) == 0 { return true }
        }
    }
    return false
}

func shouldIgnoreSyncRelativePath(_ relativePath: String, excludePatterns: [String]) -> Bool {
    syncPathContainsHiddenPathComponent(relativePath)
        || syncPathIsConflictArtifact(relativePath)
        || syncPathIsTransientTransferArtifact(relativePath)
        || syncPathIsExcluded(relativePath, excludePatterns: excludePatterns)
}

private final class SyncPairWorker {
    private let pair: SyncPair
    private let store: SQLiteStore
    private let secrets: KeychainSecretStore
    private let specPath: String
    private let log: (String) -> Void
    private let clientInfoDelegate = DaemonClientInfoDelegate()

    init(pair: SyncPair, store: SQLiteStore, secrets: KeychainSecretStore, specPath: String, log: @escaping (String) -> Void) {
        self.pair = pair
        self.store = store
        self.secrets = secrets
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
        let spec = P7Spec(withPath: specPath)
        let control = AsyncConnection(withSpec: spec)
        control.clientInfoDelegate = clientInfoDelegate
        control.nick = kDaemonNick
        control.interactive = true
        let url = try await connectControlIfNeeded(connection: control)
        defer { disconnectControl(connection: control) }

        _ = try await runCycle(connection: control, spec: spec, url: url)
    }

    func runCycle(connection control: AsyncConnection, spec: P7Spec, url: Url) async throws -> Bool {
        try prepareLocalRoot()
        let remoteResult = try await fetchRemoteInventory(connection: control)
        let local = try await fetchLocalInventory()
        try await performReconcile(
            connection: control,
            spec: spec,
            url: url,
            remote: remoteResult.remote,
            local: local,
            allowRemotePrune: remoteResult.remoteInventoryAvailable && pair.deleteRemoteEnabled
        )
        return remoteResult.remoteInventoryAvailable
    }

    func prepareLocalRoot() throws {
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
    }

    func connectControlIfNeeded(connection control: AsyncConnection) async throws -> Url {
        log("sync.connect pair=\(pair.id) kind=control endpoint=\(pair.endpoint.serverURL)")

        let url = try makeURL(endpoint: resolvedEndpoint())
        try await withTimeout(seconds: 10, label: "connect") {
            try control.connect(withUrl: url)
        }
        log("sync.connected pair=\(pair.id) kind=control")
        return url
    }

    func disconnectControl(connection control: AsyncConnection) {
        log("sync.disconnect pair=\(pair.id) kind=control")
        control.disconnect()
    }

    func fetchRemoteInventory(connection control: AsyncConnection) async throws -> (remote: [String: RemoteEntry], remoteInventoryAvailable: Bool) {
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
                    userInfo: [
                        NSLocalizedDescriptionKey: "Remote listing failed; skipping sync cycle to avoid conflict amplification",
                        NSUnderlyingErrorKey: error
                    ]
                )
            }
        }
        return (remote, remoteInventoryAvailable)
    }

    func fetchLocalInventory() async throws -> [String: LocalEntry] {
        log("sync.scan_local_start pair=\(pair.id) path=\(pair.localPath)")
        let local = try await withTimeout(seconds: 20, label: "scan_local") {
            try self.scanLocalTree()
        }
        log("sync.scan_local_done pair=\(pair.id) items=\(local.count)")
        return local
    }

    func performReconcile(
        connection control: AsyncConnection,
        spec: P7Spec,
        url: Url,
        remote: [String: RemoteEntry],
        local: [String: LocalEntry],
        allowRemotePrune: Bool
    ) async throws {
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
                    allowRemotePrune: allowRemotePrune
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

    private func resolvedEndpoint() throws -> SyncEndpoint {
        var endpoint = pair.endpoint
        endpoint.password = try secrets.readPassword(pairID: pair.id) ?? ""
        return endpoint
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
                if shouldIgnore(relativePath: relativePath) { continue }

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

            if shouldIgnore(relativePath: relativePath) {
                enumerator.skipDescendants()
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
                    if let snapshot = store.uploadedSnapshot(pairID: pair.id, relativePath: rel) {
                        // We previously synced this file. Its local absence means it was deleted locally.
                        // Exception: if remote was modified after our last upload, remote wins (re-download).
                        let remoteMtime = r.modificationDate?.timeIntervalSince1970 ?? 0
                        if remoteMtime > snapshot.modificationTime + 1.0 {
                            try await downloadFile(
                                spec: spec,
                                url: url,
                                remoteAbsolutePath: r.absolutePath,
                                localRelativePath: rel,
                                remoteModificationDate: r.modificationDate
                            )
                            log("sync.pull pair=\(pair.id) path=\(rel) reason=local_deleted_remote_modified")
                        } else {
                            try await deleteRemote(connection: control, relativePath: rel)
                            try store.removeUploadedSnapshot(pairID: pair.id, relativePath: rel)
                            log("sync.delete_remote pair=\(pair.id) path=\(rel) reason=local_deleted")
                        }
                    } else {
                        // No snapshot — new remote file, download it.
                        try await downloadFile(
                            spec: spec,
                            url: url,
                            remoteAbsolutePath: r.absolutePath,
                            localRelativePath: rel,
                            remoteModificationDate: r.modificationDate
                        )
                        log("sync.pull pair=\(pair.id) path=\(rel)")
                    }
                }

            case let (nil, l?):
                if !l.isDirectory {
                    if let snapshot = store.uploadedSnapshot(pairID: pair.id, relativePath: rel) {
                        // We previously synced this file. Its remote absence means it was deleted remotely.
                        // Exception: if local was modified since our last upload, local wins (re-upload).
                        let localMtime = l.modificationDate?.timeIntervalSince1970 ?? 0
                        if snapshot.size != l.size || abs(snapshot.modificationTime - localMtime) > 1.0 {
                            log("sync.push_try pair=\(pair.id) path=\(rel) reason=remote_deleted_local_modified")
                            try await uploadFile(spec: spec, url: url, localRelativePath: rel, remoteRelativePath: rel)
                            try store.markUploaded(
                                pairID: pair.id,
                                relativePath: rel,
                                size: l.size,
                                modificationTime: localMtime
                            )
                            log("sync.push pair=\(pair.id) path=\(rel) reason=remote_deleted_local_modified")
                        } else {
                            try deleteLocal(relativePath: rel)
                            try store.removeUploadedSnapshot(pairID: pair.id, relativePath: rel)
                            log("sync.delete_local pair=\(pair.id) path=\(rel) reason=remote_deleted")
                        }
                    } else {
                        // No snapshot — new local file, upload it.
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
                }

            case let (r?, l?):
                guard !r.isDirectory && !l.isDirectory else { continue }

                // If the local file matches our last-uploaded snapshot, the remote mtime
                // difference is caused by our own previous upload (the server assigned its
                // own timestamp). Treat the file as in-sync to break the push→pull loop.
                if let snapshot = store.uploadedSnapshot(pairID: pair.id, relativePath: rel) {
                    let localMtime = l.modificationDate?.timeIntervalSince1970 ?? 0
                    if snapshot.size == l.size && abs(snapshot.modificationTime - localMtime) <= 1.0 {
                        continue
                    }
                }

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
        log("sync.transfer_connect pair=\(pair.id) kind=download path=\(localRelativePath)")
        let tconn = AsyncConnection(withSpec: spec)
        tconn.clientInfoDelegate = clientInfoDelegate
        tconn.nick = kDaemonNick
        tconn.interactive = false
        try tconn.connect(withUrl: url)
        defer {
            log("sync.transfer_disconnect pair=\(pair.id) kind=download path=\(localRelativePath)")
            tconn.disconnect()
        }

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

        log("sync.transfer_connect pair=\(pair.id) kind=upload path=\(localRelativePath)")
        let tconn = AsyncConnection(withSpec: spec)
        tconn.clientInfoDelegate = clientInfoDelegate
        tconn.nick = kDaemonNick
        tconn.interactive = false
        try tconn.connect(withUrl: url)
        defer {
            log("sync.transfer_disconnect pair=\(pair.id) kind=upload path=\(localRelativePath)")
            tconn.disconnect()
        }

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
        syncPathContainsHiddenPathComponent(relativePath)
    }

    private func isConflictArtifact(relativePath: String) -> Bool {
        syncPathIsConflictArtifact(relativePath)
    }

    private func isTransientTransferArtifact(relativePath: String) -> Bool {
        syncPathIsTransientTransferArtifact(relativePath)
    }

    /// Returns true if `relativePath` matches any of the pair's exclude patterns.
    /// Patterns without a "/" are matched against the last path component only (like .gitignore).
    /// Patterns containing "/" are matched against the full relative path.
    private func isExcluded(relativePath: String) -> Bool {
        syncPathIsExcluded(relativePath, excludePatterns: pair.excludePatterns)
    }

    private func shouldIgnore(relativePath: String) -> Bool {
        containsHiddenPathComponent(relativePath)
            || isConflictArtifact(relativePath: relativePath)
            || isTransientTransferArtifact(relativePath: relativePath)
            || isExcluded(relativePath: relativePath)
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

private final class PairSession {
    private let state: DaemonState
    private let specPath: String
    private let pairID: String
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var shouldStop = false
    private var pendingSyncNow = false
    private var pendingReconnect = false
    private var pendingSyncReason: String?
    private var pendingReconnectReason: String?
    private var loopSignal: CheckedContinuation<Void, Never>?
    private var currentConnection: AsyncConnection?
    private var scheduledWakeTask: Task<Void, Never>?
    private var wakeTimedOut = false
    private var retryCount = 0
    private let reconnectSchedule: [TimeInterval] = [1, 2, 4, 8, 15, 30, 60]
    private let steadyStateSyncInterval: TimeInterval = 30

    init(pairID: String, state: DaemonState, specPath: String) {
        self.pairID = pairID
        self.state = state
        self.specPath = specPath
    }

    func start() {
        lock.lock()
        guard task == nil else {
            lock.unlock()
            signalSyncNow(reason: "session_start_existing")
            return
        }
        shouldStop = false
        task = Task.detached(priority: .utility) { [weak self] in
            await self?.run()
        }
        lock.unlock()
    }

    func stop() {
        let taskToCancel: Task<Void, Never>?
        let connection: AsyncConnection?
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        shouldStop = true
        taskToCancel = task
        connection = currentConnection
        currentConnection = nil
        continuation = loopSignal
        loopSignal = nil
        scheduledWakeTask?.cancel()
        scheduledWakeTask = nil
        task = nil
        pendingReconnect = false
        pendingSyncNow = false
        lock.unlock()
        connection?.disconnect()
        continuation?.resume()
        taskToCancel?.cancel()
        state.setRuntimeStatus(pairID: pairID, state: .disconnected, retryCount: 0, nextRetryAt: .some(nil))
        state.appendLog("pair.session_stop id=\(pairID)")
    }

    func signalSyncNow(reason: String = "manual") {
        resumeLoop(syncNow: true, reconnect: false, dueToTimeout: false, reason: reason)
    }

    func signalReconnectNow(reason: String = "manual") {
        resumeLoop(syncNow: true, reconnect: true, dueToTimeout: false, reason: reason)
    }

    private func resumeLoop(syncNow: Bool, reconnect: Bool, dueToTimeout: Bool, reason: String?) {
        let continuation: CheckedContinuation<Void, Never>?
        let connection: AsyncConnection?
        lock.lock()
        if syncNow {
            pendingSyncNow = true
            if let reason {
                pendingSyncReason = reason
            }
        }
        if reconnect {
            pendingReconnect = true
            if let reason {
                pendingReconnectReason = reason
            }
        }
        if dueToTimeout {
            wakeTimedOut = true
        }
        continuation = loopSignal
        loopSignal = nil
        scheduledWakeTask?.cancel()
        scheduledWakeTask = nil
        connection = reconnect ? currentConnection : nil
        if reconnect {
            currentConnection = nil
        }
        lock.unlock()
        connection?.disconnect()
        continuation?.resume()
    }

    private func run() async {
        state.appendLog("pair.session_start id=\(pairID)")
        while state.isRunning() && !isStopped {
            guard let pair = state.pair(id: pairID) else {
                state.clearRuntimeStatus(pairID: pairID)
                break
            }
            if pair.paused {
                state.setRuntimeStatus(pairID: pairID, state: .paused, retryCount: 0, nextRetryAt: .some(nil))
                break
            }

            let spec = P7Spec(withPath: specPath)
            let worker = SyncPairWorker(pair: pair, store: state.store, secrets: state.secrets, specPath: specPath) { [weak state] line in
                state?.appendLog(line)
            }
            let control = AsyncConnection(withSpec: spec)
            control.clientInfoDelegate = DaemonClientInfoDelegate()
            control.nick = kDaemonNick
            control.interactive = true
            setConnection(control)

            do {
                state.setRuntimeStatus(
                    pairID: pairID,
                    state: retryCount == 0 ? .connecting : .reconnecting,
                    lastError: retryCount == 0 ? .some(nil) : nil,
                    nextRetryAt: .some(nil)
                )
                state.appendLog("pair.connecting id=\(pairID)")
                let url = try await worker.connectControlIfNeeded(connection: control)
                let now = Date()
                retryCount = 0
                state.setRuntimeStatus(
                    pairID: pairID,
                    state: .connected,
                    lastError: .some(nil),
                    retryCount: 0,
                    nextRetryAt: .some(nil),
                    lastConnectedAt: .some(now)
                )
                state.appendLog("pair.connected id=\(pairID)")
                let shouldReconnect = await runConnectedLoop(pair: pair, worker: worker, control: control, spec: spec, url: url)
                worker.disconnectControl(connection: control)
                clearConnection(control)
                if shouldReconnect {
                    continue
                }
                break
            } catch {
                worker.disconnectControl(connection: control)
                clearConnection(control)
                if handleCycleError(error, pair: pair, duringConnect: true) {
                    let delay = state.runtimeStatus(pairID: pairID)?.nextRetryAt?.timeIntervalSinceNow ?? jitteredBackoff()
                    await sleepBeforeReconnect(delay: max(0.1, delay))
                    continue
                }
                break
            }
        }
        if let pair = state.pair(id: pairID), !pair.paused, state.runtimeStatus(pairID: pairID)?.state != .paused {
            state.setRuntimeStatus(pairID: pairID, state: .disconnected, retryCount: 0, nextRetryAt: .some(nil))
        }
    }

    private func runConnectedLoop(
        pair: SyncPair,
        worker: SyncPairWorker,
        control: AsyncConnection,
        spec: P7Spec,
        url: Url
    ) async -> Bool {
        var runImmediateCycle = true
        var nextSyncAt = Date()
        while state.isRunning() && !isStopped {
            let decision = consumeSignals()
            if decision.forceReconnect {
                state.appendLog("pair.reconnect_aborted id=\(pairID) reason=\(decision.reconnectReason ?? "signal")")
                return true
            }

            let now = Date()
            let shouldRunSync = runImmediateCycle || decision.runSyncNow || now >= nextSyncAt
            if shouldRunSync {
                do {
                    state.setRuntimeStatus(pairID: pairID, state: .syncing, lastSyncStartedAt: .some(Date()))
                    let cycleReason = runImmediateCycle ? "initial_connect" : (decision.syncReason ?? "scheduled")
                    state.appendLog("pair.sync_cycle_start id=\(pairID) reason=\(cycleReason)")
                    let remoteInventoryAvailable = try await worker.runCycle(connection: control, spec: spec, url: url)
                    let completedAt = Date()
                    state.setRuntimeStatus(
                        pairID: pairID,
                        state: .connected,
                        lastError: .some(nil),
                        lastSyncCompletedAt: .some(completedAt),
                        remoteInventoryAvailable: .some(remoteInventoryAvailable)
                    )
                    state.appendLog("pair.sync_cycle_done id=\(pairID) reason=\(cycleReason)")
                    runImmediateCycle = false
                    nextSyncAt = completedAt.addingTimeInterval(steadyStateSyncInterval)
                    continue
                } catch {
                    let shouldReconnect = handleCycleError(error, pair: pair, duringConnect: false)
                    if shouldReconnect {
                        return true
                    }
                    runImmediateCycle = false
                    let retryAt = Date()
                    nextSyncAt = retryAt.addingTimeInterval(steadyStateSyncInterval)
                    continue
                }
            }

            let waitSeconds = max(0.1, nextSyncAt.timeIntervalSinceNow)
            runImmediateCycle = await waitForNextEvent(seconds: waitSeconds)
        }
        return false
    }

    private func handleCycleError(_ error: Error, pair: SyncPair, duringConnect: Bool) -> Bool {
        let errorText = describeSyncError(error)
        state.appendLog("pair.sync_cycle_error id=\(pairID) during_connect=\(duringConnect) error=\(errorText)")

        let nsError = error as NSError
        if nsError.domain == "wiredsyncd.sync", nsError.code == 950 {
            if (try? state.setPaused(id: pair.id, paused: true)) == true {
                state.appendLog("pair.paused id=\(pair.id) reason=local_path_missing_client_to_server")
                state.setRuntimeStatus(pairID: pairID, state: .paused, lastError: .some(errorText))
                return false
            }
        }

        let reconnect = duringConnect || shouldReconnect(for: error)
        if reconnect {
            retryCount += 1
            let nextRetryAt = Date().addingTimeInterval(jitteredBackoff())
            state.setRuntimeStatus(
                pairID: pairID,
                state: .reconnecting,
                lastError: .some(errorText),
                retryCount: retryCount,
                nextRetryAt: .some(nextRetryAt)
            )
            state.appendLog("pair.reconnecting id=\(pairID) during_connect=\(duringConnect) error=\(errorText)")
            state.appendLog("pair.reconnect_scheduled id=\(pairID) retry=\(retryCount) at=\(ISO8601DateFormatter().string(from: nextRetryAt))")
            return true
        }

        state.setRuntimeStatus(pairID: pairID, state: .error, lastError: .some(errorText), nextRetryAt: .some(nil))
        return false
    }

    private func waitForNextEvent(seconds: TimeInterval) async -> Bool {
        let decision = consumeSignals()
        if decision.forceReconnect || decision.runSyncNow {
            return decision.runSyncNow
        }
        _ = await waitForSignalOrTimeout(seconds: seconds, timeoutTriggersSync: false)
        return false
    }

    private func sleepBeforeReconnect(delay: TimeInterval) async {
        _ = await waitForSignalOrTimeout(seconds: delay, timeoutTriggersSync: false)
    }

    private func waitForSignalOrTimeout(seconds: TimeInterval, timeoutTriggersSync: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            var shouldResumeImmediately = false
            lock.lock()
            if pendingSyncNow || pendingReconnect || shouldStop {
                shouldResumeImmediately = true
            } else {
                loopSignal = continuation
                let timeoutTask = Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(0.05, seconds) * 1_000_000_000))
                    } catch {
                        return
                    }
                    self.resumeLoop(syncNow: timeoutTriggersSync, reconnect: false, dueToTimeout: true, reason: timeoutTriggersSync ? "timer" : nil)
                }
                scheduledWakeTask = timeoutTask
            }
            lock.unlock()
            if shouldResumeImmediately {
                continuation.resume()
            }
        }
        return consumeWakeTimeoutState()
    }

    private func jitteredBackoff() -> TimeInterval {
        let index = min(max(retryCount - 1, 0), reconnectSchedule.count - 1)
        let base = reconnectSchedule[index]
        let jitter = base * 0.2
        return max(0.5, base + Double.random(in: -jitter...jitter))
    }

    private func shouldReconnect(for error: Error) -> Bool {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           shouldReconnect(for: underlying) {
            return true
        }
        if let asyncError = error as? AsyncConnectionError {
            switch asyncError {
            case .notConnected, .writeFailed:
                return true
            case .serverError(let message):
                let code = message.enumeration(forField: "wired.error") ?? 0
                return code == 0
            }
        }
        if nsError.domain == "wiredsyncd.sync" {
            return [200, 201, 202, 203, 204, 902, 903].contains(nsError.code)
        }
        return false
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldStop
    }

    private func consumeSignals() -> (runSyncNow: Bool, forceReconnect: Bool, syncReason: String?, reconnectReason: String?) {
        lock.lock()
        let decision = (pendingSyncNow, pendingReconnect, pendingSyncReason, pendingReconnectReason)
        pendingSyncNow = false
        pendingReconnect = false
        pendingSyncReason = nil
        pendingReconnectReason = nil
        lock.unlock()
        return decision
    }

    private func setConnection(_ connection: AsyncConnection) {
        lock.lock()
        currentConnection = connection
        lock.unlock()
    }

    private func clearConnection(_ connection: AsyncConnection) {
        lock.lock()
        if currentConnection === connection {
            currentConnection = nil
        }
        lock.unlock()
    }

    private func consumeWakeTimeoutState() -> Bool {
        lock.lock()
        let timedOut = wakeTimedOut
        wakeTimedOut = false
        scheduledWakeTask?.cancel()
        scheduledWakeTask = nil
        loopSignal = nil
        lock.unlock()
        return timedOut
    }
}

private final class SyncEngine {
    private let state: DaemonState
    private let specPath: String
    private let lock = NSLock()
    private var sessionsByPairID: [String: PairSession] = [:]
    private var networkMonitor: NWPathMonitor?
    private var wakeMonitorTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var lastNetworkStatus: NWPath.Status?
    private var lastGlobalReconnectSignalAt: Date?
    private let globalSignalDebounce: TimeInterval = 15

    init(state: DaemonState, specPath: String) {
        self.state = state
        self.specPath = specPath
    }

    func start() {
        for pair in state.snapshotPairs().filter({ !$0.paused }) {
            startOrReplaceSession(for: pair.id)
        }
        installNetworkMonitor()
        installWakeMonitor()
    }

    func stop() {
        networkMonitor?.cancel()
        networkMonitor = nil
        wakeMonitorTask?.cancel()
        wakeMonitorTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        let sessions: [PairSession]
        lock.lock()
        sessions = Array(sessionsByPairID.values)
        sessionsByPairID.removeAll()
        lock.unlock()
        for session in sessions {
            session.stop()
        }
    }

    func activeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return sessionsByPairID.count
    }

    func handlePairAdded(_ pairID: String) {
        startOrReplaceSession(for: pairID)
    }

    func handlePairRemoved(_ pairID: String) {
        let session: PairSession?
        lock.lock()
        session = sessionsByPairID.removeValue(forKey: pairID)
        lock.unlock()
        session?.stop()
        state.clearRuntimeStatus(pairID: pairID)
    }

    func handlePairsRemoved(_ pairIDs: [String]) {
        for pairID in pairIDs {
            handlePairRemoved(pairID)
        }
    }

    func handlePairUpdated(_ pairID: String) {
        startOrReplaceSession(for: pairID)
    }

    func handlePairPaused(_ pairID: String) {
        let session: PairSession?
        lock.lock()
        session = sessionsByPairID.removeValue(forKey: pairID)
        lock.unlock()
        session?.stop()
        state.setRuntimeStatus(pairID: pairID, state: .paused, lastError: .some(nil), retryCount: 0, nextRetryAt: .some(nil))
    }

    func handlePairResumed(_ pairID: String) {
        startOrReplaceSession(for: pairID)
    }

    func handleReload() {
        let pairs = state.snapshotPairs()
        let desired = Set(pairs.filter { !$0.paused }.map(\.id))
        let current = Set(state.runtimeStatusesSnapshot().keys)
        for pairID in current.subtracting(Set(pairs.map(\.id))) {
            handlePairRemoved(pairID)
        }
        for pair in pairs {
            if pair.paused {
                handlePairPaused(pair.id)
            } else {
                startOrReplaceSession(for: pair.id)
            }
        }
        for stale in current.subtracting(desired) {
            handlePairPaused(stale)
        }
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
            let existingSession = session(for: pair.id)
            if existingSession == nil {
                startOrReplaceSession(for: pair.id)
                launched += 1
            }
            session(for: pair.id)?.signalSyncNow(reason: "sync_now_rpc")
        }
        return (pairs.count, launched)
    }

    private func startOrReplaceSession(for pairID: String) {
        guard let pair = state.pair(id: pairID), !pair.paused else {
            handlePairPaused(pairID)
            return
        }

        let previous: PairSession?
        let session = PairSession(pairID: pairID, state: state, specPath: specPath)
        lock.lock()
        previous = sessionsByPairID.updateValue(session, forKey: pairID)
        lock.unlock()
        previous?.stop()
        state.setRuntimeStatus(pairID: pairID, state: .disconnected, lastError: .some(nil), retryCount: 0, nextRetryAt: .some(nil))
        session.start()
    }

    private func session(for pairID: String) -> PairSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessionsByPairID[pairID]
    }

    private func signalReconnectAll(reason: String, force: Bool = false) {
        lock.lock()
        let now = Date()
        if !force, let last = lastGlobalReconnectSignalAt, now.timeIntervalSince(last) < globalSignalDebounce {
            lock.unlock()
            state.appendLog("daemon.reconnect_all_skipped reason=\(reason) debounce=true")
            return
        }
        lastGlobalReconnectSignalAt = now
        let sessions: [PairSession]
        sessions = Array(sessionsByPairID.values)
        lock.unlock()
        state.appendLog("daemon.reconnect_all reason=\(reason) sessions=\(sessions.count)")
        for session in sessions {
            session.signalReconnectNow(reason: reason)
        }
    }

    private func signalSyncAll(reason: String, force: Bool = false) {
        lock.lock()
        let now = Date()
        if !force, let last = lastGlobalReconnectSignalAt, now.timeIntervalSince(last) < globalSignalDebounce {
            lock.unlock()
            state.appendLog("daemon.sync_all_skipped reason=\(reason) debounce=true")
            return
        }
        lastGlobalReconnectSignalAt = now
        let sessions: [PairSession]
        sessions = Array(sessionsByPairID.values)
        lock.unlock()
        state.appendLog("daemon.sync_all reason=\(reason) sessions=\(sessions.count)")
        for session in sessions {
            session.signalSyncNow(reason: reason)
        }
    }

    private func installNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            let previous = self.lastNetworkStatus
            let current = path.status
            self.lastNetworkStatus = current
            self.lock.unlock()

            guard let previous else {
                self.state.appendLog("daemon.network_path_initial status=\(current)")
                return
            }
            guard previous != current else { return }

            self.state.appendLog("daemon.network_path_changed from=\(previous) to=\(current)")
            if current == .unsatisfied {
                self.state.appendLog("daemon.network_path_unavailable status=\(current)")
                return
            }
            self.signalSyncAll(reason: "network_path_changed", force: false)
        }
        monitor.start(queue: DispatchQueue(label: "wiredsyncd.network-monitor"))
        networkMonitor = monitor
    }

    private func installWakeMonitor() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.state.appendLog("daemon.did_wake")
            self?.signalSyncAll(reason: "did_wake", force: true)
        }

        wakeMonitorTask = Task.detached(priority: .background) { [weak self] in
            var previous = Date()
            while let self, self.state.isRunning() {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                let now = Date()
                if now.timeIntervalSince(previous) > 120 {
                    self.state.appendLog("daemon.sleep_wake_detected")
                    self.signalSyncAll(reason: "sleep_wake_detected", force: true)
                }
                previous = now
            }
        }
    }
}

private func describeSyncError(_ error: Error) -> String {
    let nsError = error as NSError
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return describeSyncError(underlying)
    }
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
    if !nsError.localizedDescription.isEmpty {
        return nsError.localizedDescription
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
        respondResult(id: req.id, result: state.status(), fd: fd)

    case "list_pairs":
        let rows = state.snapshotPairs().map { pair in
            let runtime = state.runtimeStatus(pairID: pair.id)
            return [
                "id": pair.id,
                "remote_path": pair.remotePath,
                "local_path": pair.localPath,
                "mode": pair.mode.rawValue,
                "delete_remote_enabled": pair.deleteRemoteEnabled ? "true" : "false",
                "server_url": pair.endpoint.serverURL,
                "login": pair.endpoint.login,
                "paused": pair.paused ? "true" : "false",
                "runtime_state": runtime?.state.rawValue ?? (pair.paused ? PairConnectionState.paused.rawValue : PairConnectionState.disconnected.rawValue),
                "runtime_last_error": runtime?.lastError as Any,
                "runtime_retry_count": runtime?.retryCount ?? 0,
                "runtime_next_retry_at": runtime?.nextRetryAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "runtime_last_connected_at": runtime?.lastConnectedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "runtime_last_sync_started_at": runtime?.lastSyncStartedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "runtime_last_sync_completed_at": runtime?.lastSyncCompletedAt.map { ISO8601DateFormatter().string(from: $0) } as Any
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
        let excludePatterns = (params["exclude_patterns"] ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
                excludePatterns: excludePatterns,
                endpoint: endpoint
            )
            engine.handlePairAdded(pair.id)
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
            if ok {
                engine.handlePairRemoved(pairID)
            }
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
            engine.handlePairsRemoved(removed)
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
            for pairID in updated {
                engine.handlePairUpdated(pairID)
            }
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
        let updateExcludePatterns = (params["exclude_patterns"] ?? "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let updated = try state.updatePairPolicy(
                remotePath: remotePath,
                serverURL: params["server_url"],
                login: params["login"],
                mode: mode,
                deleteRemoteEnabled: deleteRemoteEnabled,
                excludePatterns: updateExcludePatterns
            )
            for pairID in updated {
                engine.handlePairUpdated(pairID)
            }
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
            if ok {
                engine.handlePairPaused(pairID)
            }
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
            if ok {
                engine.handlePairResumed(pairID)
            }
            respondResult(id: req.id, result: ["ok": ok], fd: fd)
        } catch {
            respondError(id: req.id, code: -32000, message: "resume_pair failed: \(error.localizedDescription)", fd: fd)
        }

    case "reload":
        do {
            try state.reload()
            engine.handleReload()
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
        WiredProtocolSpec.bundledSpecURL(),
        env["WIRED_SYNCD_RESOURCE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("wired.xml", isDirectory: false) },
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
