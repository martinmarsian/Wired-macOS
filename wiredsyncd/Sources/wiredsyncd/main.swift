import Foundation
import Darwin
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SyncMode: String, Codable {
    case serverToClient = "server_to_client"
    case clientToServer = "client_to_server"
    case bidirectional = "bidirectional"
}

struct SyncPair: Codable {
    var id: String
    var remotePath: String
    var localPath: String
    var mode: SyncMode
    var paused: Bool
    var createdAt: Date
    var updatedAt: Date
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

struct RPCErrorPayload: Codable {
    var code: Int
    var message: String
}

struct RPCResponse<T: Codable>: Codable {
    var jsonrpc: String = "2.0"
    var id: String?
    var result: T?
    var error: RPCErrorPayload?
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
            throw NSError(domain: "wiredsyncd", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    func upsert(pair: SyncPair) throws {
        guard let db else { return }
        let sql = """
        INSERT INTO sync_pairs(id, remote_path, local_path, mode, paused, created_at, updated_at)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          remote_path=excluded.remote_path,
          local_path=excluded.local_path,
          mode=excluded.mode,
          paused=excluded.paused,
          updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, pair.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, pair.remotePath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, pair.localPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, pair.mode.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 5, pair.paused ? 1 : 0)
        sqlite3_bind_double(stmt, 6, pair.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 7, pair.updatedAt.timeIntervalSince1970)

        _ = sqlite3_step(stmt)
    }

    func remove(id: String) throws {
        try execute("DELETE FROM sync_pairs WHERE id = '\(id.replacingOccurrences(of: "'", with: "''"))';")
    }

    func enqueue(pairID: String, opKind: String, payload: String) throws {
        guard let db else { return }
        let sql = "INSERT INTO op_queue(pair_id, op_kind, payload, created_at) VALUES(?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, pairID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, opKind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, payload, -1, SQLITE_TRANSIENT)
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
}

final class DaemonState {
    let paths: PathLayout
    let store: SQLiteStore
    private(set) var config: DaemonConfig
    private(set) var running: Bool = true
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
        return try JSONDecoder().decode(DaemonConfig.self, from: data)
    }

    private func saveConfig() throws {
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

    func status() -> [String: Any] {
        [
            "pairs_count": config.pairs.count,
            "queue_depth": store.queueDepth(),
            "socket_path": paths.socketPath.path,
            "config_path": paths.configPath.path,
            "state_path": paths.statePath.path,
            "running": running
        ]
    }

    func addPair(remotePath: String, localPath: String, mode: SyncMode) throws -> SyncPair {
        let now = Date()
        var pair = SyncPair(
            id: UUID().uuidString,
            remotePath: remotePath,
            localPath: localPath,
            mode: mode,
            paused: false,
            createdAt: now,
            updatedAt: now
        )

        if let index = config.pairs.firstIndex(where: { $0.remotePath == remotePath && $0.localPath == localPath }) {
            pair = config.pairs[index]
            pair.mode = mode
            pair.paused = false
            pair.updatedAt = now
            config.pairs[index] = pair
        } else {
            config.pairs.append(pair)
        }

        try store.upsert(pair: pair)
        try store.enqueue(pairID: pair.id, opKind: "rescan", payload: "{}")
        try saveConfig()
        appendLog("pair.add id=\(pair.id) mode=\(pair.mode.rawValue) remote=\(pair.remotePath)")
        return pair
    }

    func removePair(id: String) throws -> Bool {
        guard let index = config.pairs.firstIndex(where: { $0.id == id }) else { return false }
        config.pairs.remove(at: index)
        try store.remove(id: id)
        try saveConfig()
        appendLog("pair.remove id=\(id)")
        return true
    }

    func setPaused(id: String, paused: Bool) throws -> Bool {
        guard let index = config.pairs.firstIndex(where: { $0.id == id }) else { return false }
        config.pairs[index].paused = paused
        config.pairs[index].updatedAt = Date()
        try store.upsert(pair: config.pairs[index])
        try saveConfig()
        appendLog("pair.\(paused ? "pause" : "resume") id=\(id)")
        return true
    }

    func reload() throws {
        config = try Self.loadConfig(path: paths.configPath)
        appendLog("config.reload")
    }

    func shutdown() {
        running = false
        appendLog("daemon.shutdown")
    }
}

private func setSocketPermissions(path: String) {
    chmod(path, mode_t(S_IRUSR | S_IWUSR))
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
    var buffer = [UInt8](repeating: 0, count: 4096)
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

private func handleRequest(_ req: RPCRequest, state: DaemonState, fd: Int32) {
    let params = req.params ?? [:]
    switch req.method {
    case "status":
        respondResult(id: req.id, result: state.status(), fd: fd)

    case "add_pair":
        guard let remotePath = params["remote_path"],
              let localPath = params["local_path"] else {
            respondError(id: req.id, code: -32602, message: "remote_path/local_path required", fd: fd)
            return
        }
        let mode = SyncMode(rawValue: params["mode"] ?? "bidirectional") ?? .bidirectional
        do {
            let pair = try state.addPair(remotePath: remotePath, localPath: localPath, mode: mode)
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

    case "logs_tail":
        let count = Int(params["count"] ?? "50") ?? 50
        let tail = state.tail(count: count)
        respondResult(id: req.id, result: ["ok": true, "lines": tail], fd: fd)

    case "shutdown":
        state.shutdown()
        respondResult(id: req.id, result: ["ok": true], fd: fd)

    default:
        respondError(id: req.id, code: -32601, message: "method not found", fd: fd)
    }
}

private func runServer() throws {
    let paths = PathLayout()
    try paths.ensureDirectories()
    unlink(paths.socketPath.path)

    let store = try SQLiteStore(path: paths.statePath.path)
    let state = try DaemonState(paths: paths, store: store)

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

    while state.running {
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

        defer { close(clientFD) }

        guard let line = readLine(from: clientFD), let req = decodeRequest(line) else {
            respondError(id: nil, code: -32700, message: "invalid json", fd: clientFD)
            continue
        }

        handleRequest(req, state: state, fd: clientFD)
    }

    unlink(paths.socketPath.path)
}

@main
struct WiredSyncDaemonMain {
    static func main() {
        do {
            try runServer()
        } catch {
            fputs("wiredsyncd: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
