//
//  FilesView.swift
//  Wired 3
//
//  Created by Rafaël Warnault on 09/01/2026.
//  Copyright © 2026 Read-Write. All rights reserved.
//

import SwiftUI
import WiredSwift
import UniformTypeIdentifiers
import CoreTransferable
#if os(macOS)
import AppKit
import ObjectiveC
import Darwin
import SQLite3
#endif

extension UTType {
    static let wiredRemoteFile = UTType(importedAs: "com.read-write.wired.remote-file")
}

private func resolvedDragItemName(preferredName: String, path: String, fallback: String) -> String {
    let trimmed = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        return trimmed
    }

    let fromPath = (path as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    if !fromPath.isEmpty && fromPath != "/" {
        return fromPath
    }

    return fallback
}

struct RemoteFileDragPayload: Codable, Transferable {
    let path: String
    let name: String
    let connectionID: UUID

    var asFileItem: FileItem {
        let effectiveName = resolvedDragItemName(preferredName: name, path: path, fallback: "file")
        return FileItem(
            effectiveName,
            path: path,
            type: .file
        )
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item, shouldAllowToOpenInPlace: true) { item in
            guard let url = FinderDragExportBroker.shared.prepareExport(for: item) else {
                throw NSError(
                    domain: "Wired.DragAndDrop",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to stage file placeholder for Finder drag."]
                )
            }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }

        CodableRepresentation(contentType: .wiredRemoteFile)
    }
}

struct RemoteFolderDragPayload: Codable, Transferable {
    let path: String
    let name: String
    let connectionID: UUID

    var asFileItem: FileItem {
        let effectiveName = resolvedDragItemName(preferredName: name, path: path, fallback: "folder")
        return FileItem(effectiveName, path: path, type: .directory)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item, shouldAllowToOpenInPlace: true) { item in
            guard let url = FinderDragExportBroker.shared.prepareExport(for: item) else {
                throw NSError(
                    domain: "Wired.DragAndDrop",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to stage folder placeholder for Finder drag."]
                )
            }
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }

        CodableRepresentation(contentType: .wiredRemoteFile)
    }
}

private final class FinderDragExportBroker {
    static let shared = FinderDragExportBroker()

    private init() {}

    func configure(transferManager: TransferManager) {
        _ = transferManager
    }

    func prepareExport(for payload: RemoteFileDragPayload) -> URL? {
        prepareExport(file: payload.asFileItem, connectionID: payload.connectionID)
    }

    func prepareExport(for payload: RemoteFolderDragPayload) -> URL? {
        prepareExport(file: payload.asFileItem, connectionID: payload.connectionID)
    }

    private func prepareExport(file: FileItem, connectionID: UUID) -> URL? {
        guard isDownloadableRemoteItem(file) else { return nil }

        let stagedURL = dragExportStagingURL(for: file, connectionID: connectionID)
        let stagedPath = stagedURL.path
        let fm = FileManager.default

        if fm.fileExists(atPath: stagedPath) {
            try? fm.removeItem(atPath: stagedPath)
        }

        if file.type == .file {
            guard fm.createFile(atPath: stagedPath, contents: nil, attributes: nil) else {
                return nil
            }
            return stagedURL
        }

        do {
            try fm.createDirectory(at: stagedURL, withIntermediateDirectories: true)
            return stagedURL
        } catch {
            return nil
        }
    }
}

private func dragExportFileName(for item: FileItem) -> String {
    let name = item.name.isEmpty ? (item.path as NSString).lastPathComponent : item.name
    return name.isEmpty ? "file" : name
}

private func dragExportTemporaryURL(for item: FileItem, connectionID: UUID) -> URL {
    let _ = connectionID
    let fileName = dragExportFileName(for: item)
    let unique = UUID().uuidString
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("WiredDragExports", isDirectory: true)
        .appendingPathComponent(unique, isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let isDirectory = (item.type.isDirectoryLike)
    return base.appendingPathComponent(fileName, isDirectory: isDirectory)
}

private func dragExportStagingURL(for item: FileItem, connectionID: UUID) -> URL {
    let baseURL = dragExportTemporaryURL(for: item, connectionID: connectionID)
    let isDirectory = (item.type.isDirectoryLike)
    guard !isDirectory else { return baseURL }
    let partialName = baseURL.lastPathComponent + ".\(Wired.transfersFileExtension)"
    return baseURL.deletingLastPathComponent().appendingPathComponent(partialName, isDirectory: false)
}

private func isDownloadableRemoteItem(_ item: FileItem) -> Bool {
    if item.path == "/" { return false }
    return item.type == .file || item.type.isDirectoryLike
}

private func normalizeSyncRemotePath(_ path: String) -> String {
    var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty { return "/" }
    while normalized.count > 1 && normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    if !normalized.hasPrefix("/") {
        normalized = "/" + normalized
    }
    return normalized
}

private struct SyncActivationNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum SyncPairStatusDisplay: Equatable {
    case hidden
    case checking
    case active
    case inactive
}

private enum SyncPairLocalOverride: Equatable {
    case checking(active: Bool)
    case sticky(active: Bool, until: Date)
}

struct WiredSyncPairDescriptor: Hashable {
    let remotePath: String
    let serverURL: String
    let login: String
    let mode: String
    let deleteRemoteEnabled: Bool
    let paused: Bool
}

enum WiredSyncDaemonIPC {
    static let defaultRPCTimeoutSeconds: Int = 8
    static let baseSupportPath = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
        .appendingPathComponent("Library/Application Support/WiredSync")
    static let runPath = (baseSupportPath as NSString).appendingPathComponent("run")
    static let socketPath = (runPath as NSString).appendingPathComponent("wiredsyncd.sock")
    static let configPath = (baseSupportPath as NSString).appendingPathComponent("config.json")
    static let statePath = (baseSupportPath as NSString).appendingPathComponent("state.sqlite")
    static let daemonInstallPath = (baseSupportPath as NSString).appendingPathComponent("daemon")
    static let daemonResourcesPath = (daemonInstallPath as NSString).appendingPathComponent("Resources")
    static let installedDaemonPath = (daemonInstallPath as NSString).appendingPathComponent("wiredsyncd")
    static let launchAgentLabel = "fr.read-write.wiredsyncd"
    static let launchAgentPath = (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
        .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    /// Must match `kDaemonVersion` in WiredSyncDaemonMain.swift.
    static let expectedDaemonVersion = "8"

    static func addPair(
        remotePath: String,
        localPath: String,
        mode: String = "bidirectional",
        deleteRemoteEnabled: Bool = false,
        serverURL: String,
        login: String,
        password: String
    ) throws -> String? {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "add_pair",
            "params": [
                "remote_path": remotePath,
                "local_path": localPath,
                "mode": mode,
                "delete_remote_enabled": deleteRemoteEnabled ? "true" : "false",
                "server_url": serverURL,
                "login": login,
                "password": password
            ]
        ]
        let response = try sendRequest(request)
        let result = response["result"] as? [String: Any]
        return result?["pair_id"] as? String
    }

    static func syncNow(remotePath: String, serverURL: String? = nil, login: String? = nil) throws -> (matched: Int, launched: Int) {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "sync_now",
            "params": [
                "remote_path": remotePath,
                "server_url": serverURL ?? "",
                "login": login ?? ""
            ]
        ]
        let response = try sendRequest(request)
        let result = response["result"] as? [String: Any]
        let matched = result?["matched"] as? Int ?? 0
        let launched = result?["launched"] as? Int ?? 0
        return (matched, launched)
    }

    static func removePairForRemote(remotePath: String, serverURL: String, login: String? = nil) throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "remove_pair_for_remote",
            "params": [
                "remote_path": remotePath,
                "server_url": serverURL,
                "login": login ?? ""
            ]
        ]
        _ = try sendRequest(request)
    }

    static func listPairedDescriptors(serverURL: String? = nil, login: String? = nil) throws -> Set<WiredSyncPairDescriptor> {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "list_pairs"
        ]
        let response = try sendRequest(request)
        guard let result = response["result"] as? [String: Any],
              let pairs = result["pairs"] as? [[String: Any]] else {
            return []
        }

        let normalizedServer = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptors: [WiredSyncPairDescriptor] = pairs.compactMap { pair in
            guard let remotePath = pair["remote_path"] as? String else { return nil }
            if let normalizedServer, !normalizedServer.isEmpty {
                guard let pairServer = pair["server_url"] as? String, pairServer == normalizedServer else { return nil }
            }
            if let normalizedLogin, !normalizedLogin.isEmpty {
                let pairLogin = (pair["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard pairLogin == normalizedLogin else { return nil }
            }
            let pairServer = (pair["server_url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pairLogin = (pair["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pausedRaw = (pair["paused"] as? String)?.lowercased() ?? "false"
            let paused = pausedRaw == "true" || pausedRaw == "1"
            let deleteRemoteRaw = (pair["delete_remote_enabled"] as? String)?.lowercased() ?? "false"
            let deleteRemoteEnabled = deleteRemoteRaw == "true" || deleteRemoteRaw == "1"
            return WiredSyncPairDescriptor(
                remotePath: normalizeSyncRemotePath(remotePath),
                serverURL: pairServer,
                login: pairLogin,
                mode: (pair["mode"] as? String) ?? "bidirectional",
                deleteRemoteEnabled: deleteRemoteEnabled,
                paused: paused
            )
        }
        return Set(descriptors)
    }

    @discardableResult
    static func renamePairForRemote(
        oldPath: String,
        newPath: String,
        serverURL: String,
        login: String
    ) throws -> Int {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "rename_pair_remote",
            "params": [
                "old_remote_path": oldPath,
                "new_remote_path": newPath,
                "server_url": serverURL,
                "login": login
            ]
        ]
        let response = try sendRequest(request)
        let result = response["result"] as? [String: Any]
        return result?["updated_count"] as? Int ?? 0
    }

    static func updatePairPolicy(
        remotePath: String,
        mode: String,
        deleteRemoteEnabled: Bool,
        serverURL: String,
        login: String
    ) throws -> Int {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "update_pair_policy",
            "params": [
                "remote_path": remotePath,
                "mode": mode,
                "delete_remote_enabled": deleteRemoteEnabled ? "true" : "false",
                "server_url": serverURL,
                "login": login
            ]
        ]
        let response = try sendRequest(request)
        let result = response["result"] as? [String: Any]
        return result?["updated_count"] as? Int ?? 0
    }

    static func listPairedRemotePaths(serverURL: String? = nil, login: String? = nil) throws -> Set<String> {
        let descriptors = try listPairedDescriptors(serverURL: serverURL, login: login)
        return Set(descriptors.filter { !$0.paused }.map(\.remotePath))
    }

    static func configuredPairedRemotePaths(serverURL: String? = nil, login: String? = nil) -> Set<String> {
        struct ConfigFile: Decodable {
            struct Pair: Decodable {
                struct Endpoint: Decodable {
                    let serverURL: String
                    let login: String?

                    enum CodingKeys: String, CodingKey {
                        case serverURL
                        case login
                    }
                }

                let remotePath: String
                let endpoint: Endpoint
                let paused: Bool?

                enum CodingKeys: String, CodingKey {
                    case remotePath
                    case endpoint
                    case paused
                }
            }

            let pairs: [Pair]
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            return []
        }

        let normalizedServer = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths = config.pairs.compactMap { pair -> String? in
            if pair.paused == true {
                return nil
            }
            if let normalizedServer, !normalizedServer.isEmpty,
               pair.endpoint.serverURL != normalizedServer {
                return nil
            }
            if let normalizedLogin, !normalizedLogin.isEmpty {
                let pairLogin = pair.endpoint.login?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if pairLogin != normalizedLogin {
                    return nil
                }
            }
            return normalizeSyncRemotePath(pair.remotePath)
        }
        return Set(paths)
    }

    static func stateDatabasePairedRemotePaths(serverURL: String? = nil, login: String? = nil) -> Set<String> {
        var database: OpaquePointer?
        guard sqlite3_open_v2(statePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }

        let sql = "SELECT remote_path, endpoint_json FROM sync_pairs WHERE paused = 0;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        let normalizedServer = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLogin = login?.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsEndpointFiltering = (normalizedServer?.isEmpty == false) || (normalizedLogin?.isEmpty == false)
        var paths: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0) else { continue }
            let remotePath = String(cString: raw)
            if needsEndpointFiltering {
                let endpointJSON: String
                if let endpointRaw = sqlite3_column_text(statement, 1) {
                    endpointJSON = String(cString: endpointRaw)
                } else {
                    endpointJSON = ""
                }
                let endpointData = Data(endpointJSON.utf8)
                let endpointObject = (try? JSONSerialization.jsonObject(with: endpointData)) as? [String: Any]
                let pairServer = (endpointObject?["serverURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let pairLogin = (endpointObject?["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let normalizedServer, !normalizedServer.isEmpty, pairServer != normalizedServer {
                    continue
                }
                if let normalizedLogin, !normalizedLogin.isEmpty, pairLogin != normalizedLogin {
                    continue
                }
            }
            paths.insert(normalizeSyncRemotePath(remotePath))
        }
        return paths
    }

    static func persistedPairedRemotePaths(serverURL: String? = nil, login: String? = nil) -> Set<String> {
        configuredPairedRemotePaths(serverURL: serverURL, login: login).union(
            stateDatabasePairedRemotePaths(serverURL: serverURL, login: login)
        )
    }

    @discardableResult
    private static func sendRequest(_ request: [String: Any]) throws -> [String: Any] {
        let method = request["method"] as? String
        let timeoutSeconds = timeoutSecondsForMethod(method)
        do {
            return try performRequest(request, timeoutSeconds: timeoutSeconds)
        } catch {
            guard shouldAttemptLaunchAgentRecovery(after: error) else {
                throw error
            }
            try installAndStartLaunchAgent()
            return try performRequest(request, timeoutSeconds: timeoutSeconds)
        }
    }

    private static func shouldAttemptLaunchAgentRecovery(after error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "wiredsyncd.ipc" else { return false }
        if nsError.code == 1 || nsError.code == 2 { return true }
        // Code 6 means the daemon returned a JSON-level error; "method not found" indicates
        // an outdated daemon that needs to be replaced before retrying.
        if nsError.code == 6,
           let msg = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
           msg == "method not found" { return true }
        return false
    }

    private static func timeoutSecondsForMethod(_ method: String?) -> Int {
        switch method {
        case "status", "list_pairs":
            return 3
        case "logs_tail":
            return 4
        case "add_pair", "remove_pair", "remove_pair_for_remote", "rename_pair_remote", "pause_pair", "resume_pair", "sync_now":
            return 8
        default:
            return defaultRPCTimeoutSeconds
        }
    }

    private static func performRequest(_ request: [String: Any], timeoutSeconds: Int) throws -> [String: Any] {
        let fd = try connectSocket(timeoutSeconds: timeoutSeconds)
        defer { close(fd) }

        let payload = try JSONSerialization.data(withJSONObject: request)
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            guard Darwin.write(fd, base, payload.count) >= 0 else {
                throw NSError(domain: "wiredsyncd.ipc", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to write request to wiredsyncd"])
            }
            _ = Darwin.write(fd, "\n", 1)
        }

        var responseBuffer = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &responseBuffer, responseBuffer.count)
        guard n > 0 else {
            throw NSError(
                domain: "wiredsyncd.ipc",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "No response from wiredsyncd (timeout \(timeoutSeconds)s)"]
            )
        }

        let data = Data(responseBuffer.prefix(n))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "wiredsyncd.ipc", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid response from wiredsyncd"])
        }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw NSError(domain: "wiredsyncd.ipc", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return json
    }

    private static func connectSocket(timeoutSeconds: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "wiredsyncd.ipc", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(socketPath.utf8.prefix(maxLen - 1))
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            raw.initialize(repeating: 0, count: maxLen)
            for (i, b) in bytes.enumerated() {
                raw[i] = CChar(bitPattern: b)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + maxLen)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addrLen)
            }
        }
        guard result == 0 else {
            close(fd)
            throw NSError(
                domain: "wiredsyncd.ipc",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to connect to wiredsyncd socket at \(socketPath)"]
            )
        }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        withUnsafePointer(to: &timeout) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<timeval>.size) { rawPtr in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, rawPtr, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, rawPtr, socklen_t(MemoryLayout<timeval>.size))
            }
        }

        return fd
    }

    private static func installAndStartLaunchAgent() throws {
        let fm = FileManager.default
        let launchAgentsDir = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Library/LaunchAgents")
        let logDir = (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Library/Logs/WiredSync")
        try fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: runPath, withIntermediateDirectories: true)

        let daemonPath = try installDaemonArtifacts()
        try? fm.removeItem(atPath: socketPath)
        print("[WiredSyncUI] launchd.install daemon=\(daemonPath) resource_root=\(daemonResourcesPath)")

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [daemonPath],
            "RunAtLoad": true,
            "KeepAlive": true,
            "WorkingDirectory": daemonInstallPath,
            "EnvironmentVariables": [
                "WIRED_SYNCD_RESOURCE_ROOT": daemonResourcesPath
            ],
            "StandardOutPath": (logDir as NSString).appendingPathComponent("wiredsyncd.out.log"),
            "StandardErrorPath": (logDir as NSString).appendingPathComponent("wiredsyncd.err.log"),
            "ProcessType": "Background"
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: launchAgentPath), options: .atomic)

        let domain = "gui/\(getuid())"
        _ = try runLaunchctl(arguments: ["bootout", "\(domain)/\(launchAgentLabel)"], allowFailure: true)
        _ = try runLaunchctl(arguments: ["bootout", domain, launchAgentPath], allowFailure: true)
        _ = try runLaunchctl(arguments: ["enable", "\(domain)/\(launchAgentLabel)"], allowFailure: true)
        _ = try runLaunchctl(arguments: ["bootstrap", domain, launchAgentPath], allowFailure: false)
        try waitForDaemonReady()
    }

    private static func installDaemonArtifacts() throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: daemonInstallPath, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: daemonResourcesPath, withIntermediateDirectories: true)

        let sourceBinaryPath = try resolveBundledDaemonExecutablePath()
        try installFile(from: sourceBinaryPath, to: installedDaemonPath, executable: true)

        if let resourcePath = resolveBundledDaemonResourcePath() {
            let installedResourcePath = (daemonResourcesPath as NSString).appendingPathComponent("wired.xml")
            try installFile(from: resourcePath, to: installedResourcePath, executable: false)
        }

        return installedDaemonPath
    }

    private static func installFile(from sourcePath: String, to destinationPath: String, executable: Bool) throws {
        let fm = FileManager.default
        let tempPath = destinationPath + ".tmp"
        try? fm.removeItem(atPath: tempPath)
        if fm.fileExists(atPath: destinationPath) {
            try fm.removeItem(atPath: destinationPath)
        }
        try fm.copyItem(atPath: sourcePath, toPath: tempPath)
        if executable {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempPath)
        } else {
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tempPath)
        }
        try fm.moveItem(atPath: tempPath, toPath: destinationPath)
    }

    private static func resolveBundledDaemonExecutablePath() throws -> String {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        var candidates: [String] = []
        if let fromEnv = env["WIRED_SYNCD_PATH"], !fromEnv.isEmpty {
            candidates.append(fromEnv)
        }
        if let aux = Bundle.main.url(forAuxiliaryExecutable: "wiredsyncd")?.path {
            candidates.append(aux)
        }
        candidates.append((Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/MacOS/wiredsyncd"))
        candidates.append((FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("wiredsyncd/.build/debug/wiredsyncd"))
        candidates.append((FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("wiredsyncd/.build/release/wiredsyncd"))
        candidates.append((NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/wiredsyncd"))
        candidates.append("/opt/homebrew/bin/wiredsyncd")
        candidates.append("/usr/local/bin/wiredsyncd")

        for candidate in candidates {
            if fm.fileExists(atPath: candidate), fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        throw NSError(
            domain: "wiredsyncd.ipc",
            code: 8,
            userInfo: [NSLocalizedDescriptionKey: "Unable to locate wiredsyncd executable. Set WIRED_SYNCD_PATH or install wiredsyncd in PATH."]
        )
    }

    private static func resolveBundledDaemonResourcePath() -> String? {
        let fm = FileManager.default
        let candidates: [String?] = [
            Bundle.main.url(forResource: "wired", withExtension: "xml")?.path,
            (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Resources/wired.xml"),
            (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("wiredsyncd/Sources/wiredsyncd/Resources/wired.xml")
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    @discardableResult
    private static func runLaunchctl(arguments: [String], allowFailure: Bool) throws -> String {
        try runExecutable(path: "/bin/launchctl", arguments: arguments, allowFailure: allowFailure)
    }

    @discardableResult
    private static func runExecutable(path: String, arguments: [String], allowFailure: Bool) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != 0, !allowFailure {
            let reason = stderr.isEmpty ? stdout : stderr
            throw NSError(
                domain: "wiredsyncd.ipc",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: path).lastPathComponent) \(arguments.joined(separator: " ")) failed: \(reason)"]
            )
        }

        return stdout + stderr
    }

    private static func waitForDaemonReady(timeout: TimeInterval = 5.0) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                do {
                    let response = try performRequest(
                        ["jsonrpc": "2.0", "id": UUID().uuidString, "method": "status"],
                        timeoutSeconds: 1
                    )
                    if let result = response["result"] as? [String: Any],
                       let version = result["version"] as? String,
                       version == expectedDaemonVersion {
                        print("[WiredSyncUI] launchd.ready socket=\(socketPath) version=\(version)")
                        return
                    }
                } catch {
                    lastError = error
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let reason = (lastError as NSError?)?.localizedDescription ?? "socket did not become ready"
        print("[WiredSyncUI] launchd.timeout socket=\(socketPath) reason=\(reason)")
        throw NSError(
            domain: "wiredsyncd.ipc",
            code: 11,
            userInfo: [NSLocalizedDescriptionKey: "wiredsyncd launchd startup timed out: \(reason)"]
        )
    }

    static func waitForPairRegistration(
        remotePath: String,
        serverURL: String,
        login: String,
        timeout: TimeInterval = 5.0
    ) throws {
        let normalizedPath = normalizeSyncRemotePath(remotePath)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if persistedPairedRemotePaths(serverURL: serverURL, login: login).contains(normalizedPath) {
                return
            }
            if let livePaths = try? listPairedRemotePaths(serverURL: serverURL, login: login),
               livePaths.contains(normalizedPath) {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw NSError(
            domain: "wiredsyncd.ipc",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "wiredsyncd did not confirm the pair for \(remotePath) on \(serverURL) as \(login)."]
        )
    }

    /// Checks whether the running daemon matches the expected version.
    /// If a version mismatch is detected (stale process after an app update), the daemon
    /// is replaced transparently via `kickstart -k`.  Safe to call at every app launch.
    static func ensureDaemonIsCurrentVersion() {
        Task.detached(priority: .background) {
            guard let result = try? performRequest(
                ["jsonrpc": "2.0", "id": UUID().uuidString, "method": "status"],
                timeoutSeconds: 3
            ),
            let data = result["result"] as? [String: Any] else {
                // Daemon unreachable – will be installed on next IPC call.
                return
            }
            let runningVersion = data["version"] as? String ?? ""
            guard runningVersion != expectedDaemonVersion else { return }

            // Version mismatch: reinstall plist and replace the running process.
            try? installAndStartLaunchAgent()
        }
    }
}

#if os(macOS)
private enum RemoteFolderIconKind: String {
    case directory
    case uploads
    case dropbox
    case sync
}

private enum SyncContextMenuItemTag {
    static let status = 9_101
    static let toggle = 9_102
    static let syncNow = 9_103
}

private final class RemoteFolderIconCache {
    static let shared = RemoteFolderIconCache()
    private var cache: [String: NSImage] = [:]

    private init() {}

    func icon(for kind: RemoteFolderIconKind, size: CGFloat) -> NSImage {
        let normalizedSize = max(1, Int(round(size)))
        let key = "\(kind.rawValue)-\(normalizedSize)"
        if let cached = cache[key] {
            return cached
        }

        let icon = makeIcon(for: kind, size: CGFloat(normalizedSize))
        cache[key] = icon
        return icon
    }

    private func makeIcon(for kind: RemoteFolderIconKind, size: CGFloat) -> NSImage {
        let frame = NSSize(width: size, height: size)
        let base = (NSWorkspace.shared.icon(for: .folder).copy() as? NSImage)
            ?? NSWorkspace.shared.icon(for: .folder)
        base.size = frame

        guard kind != .directory else {
            return base
        }

        let badgeName: String = {
            switch kind {
            case .uploads: return "UploadsBadge"
            case .dropbox: return "DropBoxBadge"
            case .sync: return "SyncBadge"
            case .directory: return ""
            }
        }()
        guard let badgeImage = loadBadgeImage(named: badgeName)?.copy() as? NSImage else {
            return base
        }
        let badgeScale: CGFloat = 1.60
        let badgeSize = NSSize(width: frame.width * badgeScale, height: frame.height * badgeScale)
        let badgeRect = NSRect(
            x: frame.width - badgeSize.width,
            y: 0,
            width: badgeSize.width,
            height: badgeSize.height
        )
        badgeImage.size = badgeRect.size

        let composed = NSImage(size: frame)
        composed.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: frame))
        badgeImage.draw(in: badgeRect)
        composed.unlockFocus()
        return composed
    }

    private func loadBadgeImage(named name: String) -> NSImage? {
        if let image = NSImage(named: name) {
            return image
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private func remoteItemIconImage(for item: FileItem, size: CGFloat) -> NSImage {
    let icon: NSImage

    switch item.type {
    case .file:
        let ext = (item.name as NSString).pathExtension
        let contentType = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        icon = NSWorkspace.shared.icon(for: contentType)
    case .directory:
        icon = RemoteFolderIconCache.shared.icon(for: .directory, size: size)
    case .uploads:
        icon = RemoteFolderIconCache.shared.icon(for: .uploads, size: size)
    case .dropbox:
        icon = RemoteFolderIconCache.shared.icon(for: .dropbox, size: size)
    case .sync:
        icon = RemoteFolderIconCache.shared.icon(for: .sync, size: size)
    }

    let copy = (icon.copy() as? NSImage) ?? icon
    copy.size = NSSize(width: size, height: size)
    return copy
}
#endif

private extension View {
    @ViewBuilder
    func remoteDraggable(item: FileItem, connectionID: UUID, isDirectory: Bool) -> some View {
        if isDirectory {
            self.draggable(
                RemoteFolderDragPayload(
                    path: item.path,
                    name: resolvedDragItemName(preferredName: item.name, path: item.path, fallback: "folder"),
                    connectionID: connectionID
                )
            )
        } else {
            self.draggable(
                RemoteFileDragPayload(
                    path: item.path,
                    name: resolvedDragItemName(preferredName: item.name, path: item.path, fallback: "file"),
                    connectionID: connectionID
                )
            )
        }
    }
}

struct FilesView: View {
    private struct UploadConflict: Identifiable {
        let id = UUID()
        let localPath: String
        let remotePath: String
    }

    @Environment(ConnectionController.self) private var connectionController
    @Environment(ConnectionRuntime.self) private var runtime
    @EnvironmentObject private var transfers: TransferManager

    let connectionID: UUID

    @ObservedObject var filesViewModel: FilesViewModel

    @State private var pendingDeleteItems: [FileItem] = []
    @State private var showDeleteSelectionConfirmation: Bool = false
    @State private var createFolderTargetOverride: FileItem? = nil
    @State private var pendingDownloadItems: [FileItem] = []
    @State private var pendingUploadConflicts: [UploadConflict] = []
    @State private var activeUploadConflict: UploadConflict? = nil
    @State private var infoSheetItem: FileItem? = nil
    @State private var primarySelectionPath: String? = nil
    @State private var selectedItemsForToolbar: [FileItem] = []
    @State private var backDirectoryHistory: [String] = []
    @State private var forwardDirectoryHistory: [String] = []
    @State private var currentDirectoryPath: String = "/"
    @State private var isApplyingHistoryNavigation: Bool = false
    @State private var syncActivationNotice: SyncActivationNotice? = nil
    @State private var pendingDeactivateSyncDirectory: FileItem? = nil
    @State private var showDeactivateSyncConfirmation: Bool = false
    @State private var pairedSyncRemotePaths: Set<String> = []
    @State private var pairedSyncDescriptors: Set<WiredSyncPairDescriptor> = []
    @State private var syncPairLocalOverrides: [String: SyncPairLocalOverride] = [:]
    @State private var syncPairModeReconciliationInFlight: Set<String> = []
    @State private var isSyncPairStatusRefreshing: Bool = false
    @State private var syncPairStatusRefreshToken: UUID? = nil
    @State private var lastSyncPairStatusRefreshAt: Date = .distantPast
    @State private var syncPairStatusRefreshTask: Task<Void, Never>? = nil
    @State private var syncPairPollingTask: Task<Void, Never>? = nil
    @State private var syncPairStatusVersion: Int = 0
    @State private var selectedSyncStatusPath: String? = nil
    
    @State private var currentSearchTask: Task<Void, Never>? = nil

    private var selectedItem: FileItem? {
        switch filesViewModel.selectedFileViewType {
        case .columns:
            guard let primarySelectionPath else { return nil }
            return itemForPath(primarySelectionPath)
        case .tree:
            if let primarySelectionPath,
               let item = itemForPath(primarySelectionPath) {
                return item
            }
            return filesViewModel.selectedTreeItem()
        }
    }

    private var canGoBack: Bool {
        !backDirectoryHistory.isEmpty
    }

    private var canGoForward: Bool {
        !forwardDirectoryHistory.isEmpty
    }

    private func itemForPath(_ path: String) -> FileItem? {
        if let item = filesViewModel.columns
            .flatMap(\.items)
            .first(where: { $0.path == path }) {
            return item
        }

        if let item = filesViewModel.visibleTreeNodes()
            .map(\.item)
            .first(where: { $0.path == path }) {
            return item
        }

        if path == "/" || path == filesViewModel.treeRootPath {
            let name = path == "/" ? "/" : (path as NSString).lastPathComponent
            return FileItem(name, path: path, type: .directory)
        }

        return nil
    }

    private var selectedDirectoryForUpload: FileItem? {
        if let override = createFolderTargetOverride {
            return override
        }

        var selected: FileItem
        switch filesViewModel.selectedFileViewType {
        case .columns:
            if let lastColumn = filesViewModel.columns.last,
               let selectedID = lastColumn.selection,
               let selectedItem = lastColumn.items.first(where: { $0.id == selectedID }) {
                selected = selectedItem
            } else if let selectedItem {
                selected = selectedItem
            } else {
                return nil
            }
        case .tree:
            guard let selectedItem else { return nil }
            selected = selectedItem
        }

        if selected.type.isDirectoryLike {
            return selected
        }

        let parentPath = normalizedRemotePath(selected.path.stringByDeletingLastPathComponent)
        if let parentItem = itemForPath(parentPath), parentItem.type.isDirectoryLike {
            return parentItem
        }
        return FileItem(parentPath.lastPathComponent, path: parentPath, type: .directory)
    }

    private var selectedSyncDirectory: FileItem? {
        if let target = selectedDirectoryForUpload {
            if target.type == .sync {
                return target
            }
            if let resolved = itemForPath(target.path), resolved.type == .sync {
                return resolved
            }
        }

        if let path = primarySelectionPath,
           let directoryPath = directoryPath(from: path),
           let directoryItem = itemForPath(directoryPath),
           directoryItem.type == .sync {
            return directoryItem
        }

        return nil
    }

    private func syncDirectoryPath(for primaryPath: String?) -> String? {
        guard let primaryPath else { return nil }
        if let item = itemForPath(primaryPath) {
            if item.type == .sync {
                return normalizeSyncRemotePath(item.path)
            }
            let parentPath = normalizedRemotePath(item.path.stringByDeletingLastPathComponent)
            if let parent = itemForPath(parentPath), parent.type == .sync {
                return normalizeSyncRemotePath(parent.path)
            }
        }
        return nil
    }

    private func updatePrimarySelectionPath(_ path: String?) {
        primarySelectionPath = path
        if let syncPath = syncDirectoryPath(for: path) {
            selectedSyncStatusPath = syncPath
        } else if path != nil {
            selectedSyncStatusPath = nil
        }
    }

    private func bumpSyncPairStatusVersion() {
        syncPairStatusVersion &+= 1
    }

    private var currentSyncServerURL: String? {
        guard let connection = runtime.connection as? AsyncConnection,
              let url = connection.url else {
            return nil
        }
        return "\(url.hostname):\(url.port)"
    }

    private var currentSyncLogin: String? {
        guard let connection = runtime.connection as? AsyncConnection,
              let url = connection.url else {
            return nil
        }
        return url.login.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func visibleSyncItems() -> [FileItem] {
        let items = filesViewModel.columns.flatMap(\.items) + filesViewModel.visibleTreeNodes().map(\.item)
        var seen: Set<String> = []
        return items.filter { item in
            guard item.type == .sync else { return false }
            let path = normalizeSyncRemotePath(item.path)
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private func effectiveSyncMode(for item: FileItem) -> String? {
        guard item.type == .sync else { return nil }
        if item.syncEffectiveMode == .disabled {
            return nil
        }
        return item.syncEffectiveMode.rawValue
    }

    private func shouldEnableRemoteDelete(for item: FileItem) -> Bool {
        guard item.type == .sync else { return false }
        guard runtime.hasPrivilege("wired.account.file.sync.delete_remote") else { return false }
        switch item.syncEffectiveMode {
        case .clientToServer, .bidirectional:
            return true
        case .disabled, .serverToClient:
            return false
        }
    }

    private func reconcileSyncPairModesIfNeeded(descriptors: Set<WiredSyncPairDescriptor>) {
        guard let serverURL = currentSyncServerURL,
              let login = currentSyncLogin else { return }

        let visibleItems = visibleSyncItems()
        for item in visibleItems {
            let path = normalizeSyncRemotePath(item.path)
            guard pairedSyncRemotePaths.contains(path) else { continue }
            guard let expectedMode = effectiveSyncMode(for: item) else { continue }
            guard let descriptor = descriptors.first(where: {
                $0.remotePath == path && $0.serverURL == serverURL && $0.login == login
            }) else { continue }
            let expectedDeleteRemote = shouldEnableRemoteDelete(for: item)
            guard descriptor.mode != expectedMode || descriptor.deleteRemoteEnabled != expectedDeleteRemote else { continue }
            guard !syncPairModeReconciliationInFlight.contains(path) else { continue }

            syncPairModeReconciliationInFlight.insert(path)
            print("[WiredSyncUI] reconcile.mode remote=\(path) stored=\(descriptor.mode) effective=\(expectedMode) delete_remote=\(expectedDeleteRemote)")

            Task.detached(priority: .utility) {
                do {
                    let updatedCount = try WiredSyncDaemonIPC.updatePairPolicy(
                        remotePath: path,
                        mode: expectedMode,
                        deleteRemoteEnabled: expectedDeleteRemote,
                        serverURL: serverURL,
                        login: login
                    )
                    await MainActor.run {
                        syncPairModeReconciliationInFlight.remove(path)
                        print("[WiredSyncUI] reconcile.mode.success remote=\(path) updated=\(updatedCount) mode=\(expectedMode)")
                        scheduleSyncPairStatusRefresh(delayNanoseconds: 500_000_000, force: true, showProgress: false)
                    }
                } catch {
                    await MainActor.run {
                        syncPairModeReconciliationInFlight.remove(path)
                        print("[WiredSyncUI] reconcile.mode.error remote=\(path) error=\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func debugLogSyncStatuses(context: String, livePaths: Set<String>? = nil, persistedPaths: Set<String>? = nil) {
        let endpoint = currentSyncServerURL ?? "<none>"
        let login = (currentSyncLogin?.isEmpty == false ? currentSyncLogin! : "<none>")
        let visible = visibleSyncItems()
        let visiblePaths = visible.map { normalizeSyncRemotePath($0.path) }.sorted()
        print("[WiredSyncUI] context=\(context) endpoint=\(endpoint) login=\(login) visible=\(visiblePaths)")
        if let livePaths {
            print("[WiredSyncUI] context=\(context) live_paths=\(Array(livePaths).sorted())")
        }
        if let persistedPaths {
            print("[WiredSyncUI] context=\(context) persisted_paths=\(Array(persistedPaths).sorted())")
        }
        for item in visible.sorted(by: { $0.path < $1.path }) {
            let path = normalizeSyncRemotePath(item.path)
            let overrideDescription: String
            if let override = syncPairLocalOverrides[path] {
                switch override {
                case .checking(let active):
                    overrideDescription = "checking(\(active ? "active" : "inactive"))"
                case .sticky(let active, let until):
                    overrideDescription = "sticky(\(active ? "active" : "inactive"),until=\(until.timeIntervalSince1970))"
                }
            } else {
                overrideDescription = "none"
            }
            print(
                "[WiredSyncUI] item=\(path) status=\(String(describing: syncPairStatus(for: item))) " +
                "exists=\(syncPairExists(for: item)) paired=\(pairedSyncRemotePaths.contains(path)) override=\(overrideDescription)"
            )
        }
    }

    private func setSyncPairLocalOverride(_ override: SyncPairLocalOverride?, for path: String) {
        let normalizedPath = normalizeSyncRemotePath(path)
        if let override {
            syncPairLocalOverrides[normalizedPath] = override
        } else {
            syncPairLocalOverrides.removeValue(forKey: normalizedPath)
        }
        bumpSyncPairStatusVersion()
    }

    private func syncPairStatus(for item: FileItem) -> SyncPairStatusDisplay {
        guard item.type == .sync else { return .hidden }
        let path = normalizeSyncRemotePath(item.path)
        if let override = syncPairLocalOverrides[path] {
            switch override {
            case .checking:
                return .checking
            case .sticky(let active, let until):
                if until > Date() {
                    return active ? .active : .inactive
                }
            }
        }
        return pairedSyncRemotePaths.contains(path) ? .active : .inactive
    }

    private func syncPairExists(for item: FileItem) -> Bool {
        guard item.type == .sync else { return false }
        let path = normalizeSyncRemotePath(item.path)
        if let override = syncPairLocalOverrides[path] {
            switch override {
            case .checking(let active):
                return active
            case .sticky(let active, let until):
                if until > Date() {
                    return active
                }
            }
        }
        return pairedSyncRemotePaths.contains(path)
    }

    private var selectedDownloadableItem: FileItem? {
        guard let selectedItem, canDownload(item: selectedItem) else { return nil }
        return selectedItem
    }

    private var selectedDeletableItem: FileItem? {
        guard let selectedItem, canDelete(item: selectedItem) else { return nil }
        return selectedItem
    }

    private var selectedDeletableItems: [FileItem] {
        let source = selectedItemsForToolbar.isEmpty ? [selectedItem].compactMap { $0 } : selectedItemsForToolbar
        return uniqueItems(source).filter { canDelete(item: $0) }
    }

    private var canSetFileType: Bool {
        runtime.hasPrivilege("wired.account.file.set_type")
    }

    private func canWriteDropbox(_ item: FileItem) -> Bool {
        !item.type.isManagedAccessType || item.writable
    }

    private func canReadDropbox(_ item: FileItem) -> Bool {
        !item.type.isManagedAccessType || item.readable
    }

    private func canDownload(item: FileItem) -> Bool {
        runtime.hasPrivilege("wired.account.transfer.download_files")
        && isDownloadableRemoteItem(item)
        && canReadDropbox(item)
    }

    private func canDelete(item: FileItem) -> Bool {
        guard item.path != "/" else { return false }
        if item.type == .sync {
            return item.writable
        }
        if item.type == .dropbox {
            return item.readable && item.writable
        }
        return runtime.hasPrivilege("wired.account.file.delete_files")
    }

    private func canUpload(to directory: FileItem) -> Bool {
        guard directory.type.isDirectoryLike else { return false }

        let canUploadFiles = runtime.hasPrivilege("wired.account.transfer.upload_files")
        let canUploadDirectories = runtime.hasPrivilege("wired.account.transfer.upload_directories")
        guard canUploadFiles || canUploadDirectories else { return false }

        if directory.type.isManagedAccessType {
            return directory.writable
        }

        if directory.type == .directory {
            return runtime.hasPrivilege("wired.account.transfer.upload_anywhere")
        }

        return true
    }

    private func canCreateFolder(in directory: FileItem) -> Bool {
        guard directory.type.isDirectoryLike else { return false }
        if directory.type.isManagedAccessType {
            return directory.writable
        }
        return runtime.hasPrivilege("wired.account.file.create_directories")
    }

    private func canGetInfo(for item: FileItem) -> Bool {
        guard runtime.hasPrivilege("wired.account.file.get_info") else { return false }
        guard item.type.isManagedAccessType else { return true }
        if item.type == .sync && runtime.hasPrivilege("wired.account.file.set_permissions") {
            return true
        }
        return item.readable
    }

    private func activateSync(for directory: FileItem) {
#if os(macOS)
        guard runtime.hasPrivilege("wired.account.file.sync.sync_files") else {
            syncActivationNotice = SyncActivationNotice(
                title: "Sync Error",
                message: "Your account is not allowed to activate sync pairs."
            )
            return
        }

        guard let connection = runtime.connection as? AsyncConnection,
              let url = connection.url else {
            syncActivationNotice = SyncActivationNotice(
                title: "Sync Error",
                message: "No active Wired connection available for sync activation."
            )
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Select the local folder paired with \(directory.path)"

        guard panel.runModal() == .OK, let localURL = panel.url else { return }

        let currentDirectory = filesViewModel.currentItem(path: directory.path) ?? directory
        guard let mode = effectiveSyncMode(for: currentDirectory) else {
            syncActivationNotice = SyncActivationNotice(
                title: "Sync Error",
                message: "The selected sync folder is disabled for your account."
            )
            return
        }
        let serverURL = "\(url.hostname):\(url.port)"
        let login = url.login.trimmingCharacters(in: .whitespacesAndNewlines)
        let deleteRemoteEnabled = shouldEnableRemoteDelete(for: currentDirectory)

        Task.detached(priority: .userInitiated) {
            await MainActor.run {
                setSyncPairLocalOverride(.checking(active: true), for: directory.path)
                print("[WiredSyncUI] activate path=\(directory.path) sync_mode=\(mode) delete_remote=\(deleteRemoteEnabled)")
            }
            do {
                let _ = try WiredSyncDaemonIPC.addPair(
                    remotePath: directory.path,
                    localPath: localURL.path,
                    mode: mode,
                    deleteRemoteEnabled: deleteRemoteEnabled,
                    serverURL: serverURL,
                    login: login,
                    password: url.password
                )
                try WiredSyncDaemonIPC.waitForPairRegistration(
                    remotePath: directory.path,
                    serverURL: serverURL,
                    login: login
                )
                let syncResult = try WiredSyncDaemonIPC.syncNow(
                    remotePath: directory.path,
                    serverURL: serverURL,
                    login: login
                )
                await MainActor.run {
                    pairedSyncRemotePaths.insert(normalizeSyncRemotePath(directory.path))
                    setSyncPairLocalOverride(.sticky(active: true, until: Date().addingTimeInterval(15)), for: directory.path)
                    // Delay the reconciliation refresh so the daemon has time to settle;
                    // the manual insert above is already the correct optimistic state.
                    scheduleSyncPairStatusRefresh(delayNanoseconds: 2_000_000_000, force: true, showProgress: false)
                    debugLogSyncStatuses(
                        context: "activate.success remote=\(normalizeSyncRemotePath(directory.path)) matched=\(syncResult.matched) launched=\(syncResult.launched)"
                    )
                    syncActivationNotice = SyncActivationNotice(
                        title: "Sync Enabled",
                        message: "Pair created for:\n\(directory.path)\n↔\n\(localURL.path)\nMode: \(mode)\n\nSync matched: \(syncResult.matched), launched: \(syncResult.launched)"
                    )
                }
            } catch {
                await MainActor.run {
                    setSyncPairLocalOverride(nil, for: directory.path)
                    debugLogSyncStatuses(context: "activate.error remote=\(normalizeSyncRemotePath(directory.path)) error=\(error.localizedDescription)")
                    syncActivationNotice = SyncActivationNotice(
                        title: "Sync Error",
                        message: error.localizedDescription
                    )
                }
            }
        }
#endif
    }

    private func syncNow(for directory: FileItem) {
#if os(macOS)
        let serverURL = currentSyncServerURL
        let login = currentSyncLogin
        Task.detached(priority: .userInitiated) {
            do {
                let result = try WiredSyncDaemonIPC.syncNow(
                    remotePath: directory.path,
                    serverURL: serverURL,
                    login: login
                )
                await MainActor.run {
                    refreshSyncPairStatus(force: true, showProgress: false)
                    debugLogSyncStatuses(
                        context: "sync_now.success remote=\(normalizeSyncRemotePath(directory.path)) matched=\(result.matched) launched=\(result.launched)"
                    )
                    syncActivationNotice = SyncActivationNotice(
                        title: result.launched > 0 ? "Sync Triggered" : "Sync Already Running",
                        message: result.launched > 0
                            ? "Immediate sync requested for:\n\(directory.path)"
                            : "A sync cycle is already running for:\n\(directory.path)\n\nWait for completion and check wiredsyncd logs."
                    )
                }
            } catch {
                await MainActor.run {
                    debugLogSyncStatuses(context: "sync_now.error remote=\(normalizeSyncRemotePath(directory.path)) error=\(error.localizedDescription)")
                    syncActivationNotice = SyncActivationNotice(
                        title: "Sync Error",
                        message: error.localizedDescription
                    )
                }
            }
        }
#endif
    }

    private func deactivateSync(for directory: FileItem) {
#if os(macOS)
        guard let connection = runtime.connection as? AsyncConnection,
              let url = connection.url else {
            syncActivationNotice = SyncActivationNotice(
                title: "Sync Error",
                message: "No active Wired connection available for sync deactivation."
            )
            return
        }

        let serverURL = "\(url.hostname):\(url.port)"
        let login = url.login.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached(priority: .userInitiated) {
            await MainActor.run {
                setSyncPairLocalOverride(.checking(active: false), for: directory.path)
            }
            do {
                try WiredSyncDaemonIPC.removePairForRemote(remotePath: directory.path, serverURL: serverURL, login: login)
                await MainActor.run {
                    pairedSyncRemotePaths.remove(normalizeSyncRemotePath(directory.path))
                    setSyncPairLocalOverride(.sticky(active: false, until: Date().addingTimeInterval(15)), for: directory.path)
                    debugLogSyncStatuses(context: "deactivate.success remote=\(normalizeSyncRemotePath(directory.path))")
                    syncActivationNotice = SyncActivationNotice(
                        title: "Sync Disabled",
                        message: "Pair removed for:\n\(directory.path)"
                    )
                    // Delay the reconciliation refresh so the daemon has time to settle;
                    // the manual remove above is already the correct optimistic state.
                    scheduleSyncPairStatusRefresh(delayNanoseconds: 2_000_000_000, force: true, showProgress: false)
                }
            } catch {
                await MainActor.run {
                    setSyncPairLocalOverride(nil, for: directory.path)
                    debugLogSyncStatuses(context: "deactivate.error remote=\(normalizeSyncRemotePath(directory.path)) error=\(error.localizedDescription)")
                    syncActivationNotice = SyncActivationNotice(
                        title: "Sync Error",
                        message: error.localizedDescription
                    )
                }
            }
        }
#endif
    }

    private func requestDeactivateSync(for directory: FileItem) {
        pendingDeactivateSyncDirectory = directory
        showDeactivateSyncConfirmation = true
    }

    private func refreshSyncPairStatus(force: Bool = false, showProgress: Bool = true) {
#if os(macOS)
        let now = Date()
        if !force, now.timeIntervalSince(lastSyncPairStatusRefreshAt) < 1.0 {
            return
        }
        lastSyncPairStatusRefreshAt = now

        let token = UUID()
        syncPairStatusRefreshToken = token
        if showProgress {
            isSyncPairStatusRefreshing = true
        }
        let serverURL = currentSyncServerURL
        let login = currentSyncLogin

        Task.detached(priority: .utility) {
            do {
                // Prefer the live daemon view, but reconcile it with the persisted daemon
                // state on disk. This keeps the UI truthful during daemon restarts and
                // socket hiccups instead of flashing false "inactive" statuses.
                let liveDescriptors = try WiredSyncDaemonIPC.listPairedDescriptors(serverURL: serverURL, login: login)
                let livePaths = Set(liveDescriptors.filter { !$0.paused }.map(\.remotePath))
                let persistedPaths = WiredSyncDaemonIPC.persistedPairedRemotePaths(serverURL: serverURL, login: login)
                let paths = livePaths.union(persistedPaths)
                await MainActor.run {
                    guard syncPairStatusRefreshToken == token else { return }
                    var effectivePaths = paths
                    var nextOverrides = syncPairLocalOverrides
                    for (path, override) in syncPairLocalOverrides {
                        switch override {
                        case .checking(let active):
                            if active {
                                effectivePaths.insert(path)
                            } else {
                                effectivePaths.remove(path)
                            }
                        case .sticky(let active, let until):
                            let daemonAgrees = active ? paths.contains(path) : !paths.contains(path)
                            if daemonAgrees || until <= Date() {
                                nextOverrides.removeValue(forKey: path)
                            } else if active {
                                effectivePaths.insert(path)
                            } else {
                                effectivePaths.remove(path)
                            }
                        }
                    }
                    syncPairLocalOverrides = nextOverrides
                    pairedSyncDescriptors = liveDescriptors
                    pairedSyncRemotePaths = effectivePaths
                    bumpSyncPairStatusVersion()
                    isSyncPairStatusRefreshing = false
                    debugLogSyncStatuses(context: "refresh.success", livePaths: livePaths, persistedPaths: persistedPaths)
                    reconcileSyncPairModesIfNeeded(descriptors: liveDescriptors)
                }
            } catch {
                let persistedPaths = WiredSyncDaemonIPC.persistedPairedRemotePaths(serverURL: serverURL, login: login)
                await MainActor.run {
                    guard syncPairStatusRefreshToken == token else { return }
                    if !persistedPaths.isEmpty {
                        var effectivePaths = persistedPaths
                        var nextOverrides = syncPairLocalOverrides
                        for (path, override) in syncPairLocalOverrides {
                            switch override {
                            case .checking(let active):
                                if active {
                                    effectivePaths.insert(path)
                                } else {
                                    effectivePaths.remove(path)
                                }
                            case .sticky(let active, let until):
                                if until <= Date() {
                                    nextOverrides.removeValue(forKey: path)
                                } else if active {
                                    effectivePaths.insert(path)
                                } else {
                                    effectivePaths.remove(path)
                                }
                            }
                        }
                        syncPairLocalOverrides = nextOverrides
                        pairedSyncRemotePaths = effectivePaths
                        bumpSyncPairStatusVersion()
                    }
                    pairedSyncDescriptors = []
                    isSyncPairStatusRefreshing = false
                    debugLogSyncStatuses(context: "refresh.error \(error.localizedDescription)", persistedPaths: persistedPaths)
                }
            }
        }
#endif
    }

    private func scheduleSyncPairStatusRefresh(delayNanoseconds: UInt64 = 300_000_000, force: Bool = false, showProgress: Bool = false) {
#if os(macOS)
        syncPairStatusRefreshTask?.cancel()
        syncPairStatusRefreshTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            refreshSyncPairStatus(force: force, showProgress: showProgress)
        }
#endif
    }

    private func startSyncPairPolling() {
#if os(macOS)
        syncPairPollingTask?.cancel()
        syncPairPollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { break }
                refreshSyncPairStatus(force: true, showProgress: false)
            }
        }
#endif
    }

    @ViewBuilder
    private var treeContent: some View {
        FilesTreeView(
            connectionID: connectionID,
            filesViewModel: filesViewModel,
            onRequestCreateFolder: { directory in
                guard canCreateFolder(in: directory) else { return }
                createFolderTargetOverride = directory
                filesViewModel.showCreateFolderSheet = true
            },
            onPrimarySelectionChange: { path in
                updatePrimarySelectionPath(path)
                registerNavigation(fromPrimarySelectionPath: path)
            },
            onSelectionItemsChange: { items in
                selectedItemsForToolbar = items
            },
            onOpenDirectory: { directory in
                Task { @MainActor in
                    guard await filesViewModel.setTreeRoot(directory.path) else { return }
                    updatePrimarySelectionPath(directory.path)
                    registerNavigation(toDirectoryPath: directory.path)
                }
            },
            onRequestUploadInDirectory: { directory in
                guard canUpload(to: directory) else { return }
                createFolderTargetOverride = directory
                filesViewModel.showFilesBrowser = true
            },
            onRequestDeleteSelection: { items in
                requestDelete(items)
            },
            onRequestDownloadSelection: { items in
                download(items)
            },
            onRequestGetInfo: { item in
                presentInfo(for: item)
            },
            onRequestSyncNow: { item in
                syncNow(for: item)
            },
            onRequestActivateSync: { item in
                activateSync(for: item)
            },
            onRequestDeactivateSync: { item in
                requestDeactivateSync(for: item)
            },
            syncPairStatusForItem: { item in
                syncPairStatus(for: item)
            },
            syncPairExistsForItem: { item in
                syncPairExists(for: item)
            },
            syncPairStatusVersion: syncPairStatusVersion,
            canSetFileType: canSetFileType,
            canGetInfoForItem: { item in
                canGetInfo(for: item)
            },
            canDownloadForItem: { item in
                canDownload(item: item)
            },
            canDeleteForItem: { item in
                canDelete(item: item)
            },
            canUploadToDirectory: { directory in
                canUpload(to: directory)
            },
            canCreateFolderInDirectory: { directory in
                canCreateFolder(in: directory)
            },
            onUploadURLs: { urls, target in
                upload(urls: urls, to: target)
            },
            onMoveRemoteItem: { sourcePath, destinationDirectory in
                try await moveRemoteItem(from: sourcePath, to: destinationDirectory)
            }
        )
        .environment(connectionController)
        .environment(runtime)
        .environmentObject(transfers)
        .onAppear {
            scheduleSyncPairStatusRefresh(delayNanoseconds: 0, force: true, showProgress: false)
        }
    }

    @ViewBuilder
    private var columnsContent: some View {
        FilesColumnsView(
            connectionID: connectionID,
            filesViewModel: filesViewModel,
            onRequestCreateFolder: { directory in
                guard canCreateFolder(in: directory) else { return }
                createFolderTargetOverride = directory
                filesViewModel.showCreateFolderSheet = true
            },
            onPrimarySelectionChange: { path in
                updatePrimarySelectionPath(path)
                registerNavigation(fromPrimarySelectionPath: path)
            },
            onSelectionItemsChange: { items in
                selectedItemsForToolbar = items
            },
            onRequestUploadInDirectory: { directory in
                guard canUpload(to: directory) else { return }
                createFolderTargetOverride = directory
                filesViewModel.showFilesBrowser = true
            },
            onRequestDeleteSelection: { items in
                requestDelete(items)
            },
            onRequestDownloadSelection: { items in
                download(items)
            },
            onRequestGetInfo: { item in
                presentInfo(for: item)
            },
            onRequestSyncNow: { item in
                syncNow(for: item)
            },
            onRequestActivateSync: { item in
                activateSync(for: item)
            },
            onRequestDeactivateSync: { item in
                requestDeactivateSync(for: item)
            },
            syncPairStatusForItem: { item in
                syncPairStatus(for: item)
            },
            syncPairExistsForItem: { item in
                syncPairExists(for: item)
            },
            syncPairStatusVersion: syncPairStatusVersion,
            canSetFileType: canSetFileType,
            canGetInfoForItem: { item in
                canGetInfo(for: item)
            },
            canDownloadForItem: { item in
                canDownload(item: item)
            },
            canDeleteForItem: { item in
                canDelete(item: item)
            },
            canUploadToDirectory: { directory in
                canUpload(to: directory)
            },
            canCreateFolderInDirectory: { directory in
                canCreateFolder(in: directory)
            },
            onUploadURLs: { urls, target in
                upload(urls: urls, to: target)
            },
            onMoveRemoteItem: { sourcePath, destinationDirectory in
                try await moveRemoteItem(from: sourcePath, to: destinationDirectory)
            }
        )
        .environment(connectionController)
        .environment(runtime)
        .environmentObject(transfers)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if filesViewModel.isSearchMode {
                HStack(spacing: 6) {
                    if filesViewModel.isSearching {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                        Text("Searching…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        let count = filesViewModel.columns.first?.items.count ?? 0
                        Text("\(count) result\(count == 1 ? "" : "s") for \u{201C}\(filesViewModel.searchText)\u{201D}")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.bar)

                Divider()
            }

            switch filesViewModel.selectedFileViewType {
            case .tree:
                treeContent

            case .columns:
                columnsContent
            }
        }
        .searchable(text: $filesViewModel.searchText)
        .onChange(of: filesViewModel.searchText, debounceTime: .milliseconds(500)) {
            if filesViewModel.searchText.isEmpty && filesViewModel.isSearchMode {
                currentSearchTask?.cancel()
                currentSearchTask = nil
                Task { await filesViewModel.clearSearch() }
            } else if filesViewModel.searchText.count > 2 {
                currentSearchTask?.cancel()
                currentSearchTask = nil
                
                triggerSearch()
            } else {
                currentSearchTask?.cancel()
                currentSearchTask = nil
                Task { await filesViewModel.clearSearch() }
            }
        }
        .fileImporter(
            isPresented: $filesViewModel.showFilesBrowser,
            allowedContentTypes: [.data, .directory],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if let target = selectedDirectoryForUpload {
                    upload(urls: urls, to: target)
                }
            case .failure(let error):
                filesViewModel.error = error
            }
        }
        .sheet(isPresented: $filesViewModel.showCreateFolderSheet) {
            if let selectedFile = selectedDirectoryForUpload {
                FileFormView(
                    filesViewModel: filesViewModel,
                    parentDirectory: selectedFile,
                    onCreated: { createdPath in
                        guard filesViewModel.selectedFileViewType == .columns else { return }
                        Task { @MainActor in
                            let didReveal = await filesViewModel.revealRemotePath(createdPath)
                            guard didReveal else { return }
                            updatePrimarySelectionPath(createdPath)
                            registerNavigation(fromPrimarySelectionPath: createdPath)
                        }
                    }
                )
                    .environment(connectionController)
                    .environment(runtime)
            }
        }
        .onChange(of: filesViewModel.showCreateFolderSheet) { _, isPresented in
            if !isPresented {
                createFolderTargetOverride = nil
            }
        }
        .sheet(item: $infoSheetItem) { item in
            FileInfoSheet(filesViewModel: filesViewModel, file: item)
                .environment(runtime)
        }
        .alert("Delete File", isPresented: $filesViewModel.showDeleteConfirmation, actions: {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let item = selectedItem {
                    Task {
                        await filesViewModel.deleteFile(item.path)
                    }
                }
            }
        }, message: {
            Text("Are you sure you want to delete this file? This operation is not recoverable.")
        })
        .alert(
            pendingDeleteItems.count > 1 ? "Delete Files" : "Delete File",
            isPresented: $showDeleteSelectionConfirmation,
            actions: {
                Button("Cancel", role: .cancel) {
                    pendingDeleteItems.removeAll()
                }
                Button("Delete", role: .destructive) {
                    let items = pendingDeleteItems
                    pendingDeleteItems.removeAll()

                    Task {
                        for item in items where item.path != "/" {
                            await filesViewModel.deleteFile(item.path)
                        }
                    }
                }
            },
            message: {
                Text("Are you sure you want to delete this selection? This operation is not recoverable.")
            }
        )
        .alert(item: $activeUploadConflict) { conflict in
            Alert(
                title: Text("Upload Blocked"),
                message: Text("A remote file already exists:\n\(conflict.remotePath)\n\nLocal file:\n\(conflict.localPath)"),
                dismissButton: .default(Text("OK")) {
                    processPendingUploadConflicts()
                }
            )
        }
        .alert(
            "Deactivate Sync Pair",
            isPresented: $showDeactivateSyncConfirmation,
            actions: {
                Button("Cancel", role: .cancel) {
                    pendingDeactivateSyncDirectory = nil
                }
                Button("Deactivate", role: .destructive) {
                    if let directory = pendingDeactivateSyncDirectory {
                        deactivateSync(for: directory)
                    }
                    pendingDeactivateSyncDirectory = nil
                }
            },
            message: {
                let targetPath = pendingDeactivateSyncDirectory?.path ?? "this folder"
                Text("Disable synchronization for \(targetPath)? The local folder is kept, only the pairing is removed.")
            }
        )
        .alert(item: $syncActivationNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .errorAlert(
            error: $filesViewModel.error,
            source: "Files",
            serverName: nil,
            connectionID: connectionID
        )
        .onChange(of: filesViewModel.selectedFileViewType) { _, newValue in
            updatePrimarySelectionPath(nil)
            selectedSyncStatusPath = nil
            selectedItemsForToolbar.removeAll()
            Task {
                if newValue == .tree && !filesViewModel.isSearchMode {
                    await filesViewModel.loadTreeRoot()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .revealRemoteTransferPath)) { notification in
            guard let request = notification.object as? RemoteTransferPathRequest else { return }
            guard request.connectionID == connectionID else { return }

            Task { @MainActor in
                let didReveal = await filesViewModel.revealRemotePath(request.path)
                if didReveal {
                    registerNavigation(fromPrimarySelectionPath: request.path)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiredFileDirectoryChanged)) { notification in
            guard let event = notification.object as? RemoteDirectoryEvent else { return }
            guard event.connectionID == connectionID else { return }

            Task { @MainActor in
                filesViewModel.remoteDirectoryChanged(event.path)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wiredFileDirectoryDeleted)) { notification in
            guard let event = notification.object as? RemoteDirectoryEvent else { return }
            guard event.connectionID == connectionID else { return }

            Task { @MainActor in
                await filesViewModel.remoteDirectoryDeleted(event.path)
            }
        }
        .onAppear {
            WiredSyncDaemonIPC.ensureDaemonIsCurrentVersion()
            scheduleSyncPairStatusRefresh(delayNanoseconds: 0, force: true, showProgress: false)
            startSyncPairPolling()
        }
        .onChange(of: selectedSyncStatusPath) { _, _ in
            scheduleSyncPairStatusRefresh(delayNanoseconds: 300_000_000, force: false, showProgress: false)
        }
        .onDisappear {
            syncPairStatusRefreshTask?.cancel()
            syncPairPollingTask?.cancel()
            Task { @MainActor in
                await filesViewModel.clearDirectorySubscriptions()
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("", selection: $filesViewModel.selectedFileViewType) {
                Image(systemName: "rectangle.split.3x1").tag(FileViewType.columns)
                Image(systemName: "list.bullet.indent").tag(FileViewType.tree)
            }
            .help("Display Mode")
            .pickerStyle(.segmented)
            .frame(width: 80)
            
            Divider()
                .frame(height: 16)

            Button {
                Task { await navigateHistory(backward: true) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Navigate Backwark")
            .disabled(!canGoBack)

            Button {
                Task { await navigateHistory(backward: false) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Navigate Forward")
            .disabled(!canGoForward)
            
            Divider()
                .frame(height: 16)

            Button {
                Task {
                    switch filesViewModel.selectedFileViewType {
                    case .tree:
                        await filesViewModel.loadTreeRoot()
                    case .columns:
                        if filesViewModel.columns.isEmpty {
                            await filesViewModel.loadRoot()
                        } else {
                            await filesViewModel.reloadSelectedColumn()
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .help("Reload Files")
            
            Divider()
                .frame(height: 16)
            
            Button {
                if let selectedFile = selectedDownloadableItem {
                    download([selectedFile])
                }
            } label: {
                Image(systemName: "arrow.down")
            }
            .help("Download File(s)")
            .disabled(selectedDownloadableItem == nil)

            Button {
                filesViewModel.showFilesBrowser = true
            } label: {
                Image(systemName: "arrow.up")
            }
            .help("Upload File(s)")
            .disabled(selectedDirectoryForUpload == nil || !(selectedDirectoryForUpload.map(canUpload(to:)) ?? false))

            Divider()
                .frame(height: 16)
            
            Button {
                guard let target = selectedDirectoryForUpload, canCreateFolder(in: target) else { return }
                createFolderTargetOverride = selectedDirectoryForUpload
                filesViewModel.showCreateFolderSheet = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Create Folder")
            .disabled(selectedDirectoryForUpload == nil || !(selectedDirectoryForUpload.map(canCreateFolder(in:)) ?? false))

            Button {
                requestDelete(selectedDeletableItems)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete File(s)")
            .disabled(selectedDeletableItems.isEmpty)

            Spacer()

            if filesViewModel.isPerformingFileNetworkActivity {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            }

//            HStack(spacing: 4) {
//                TextField("", text: $searchText, prompt: Text("Search Files…"))
//                    .textFieldStyle(.roundedBorder)
//                    .frame(maxWidth: 260)
//                    .onSubmit { triggerSearch() }
//                    .onChange(of: searchText) { _, newValue in
//                        if newValue.isEmpty && filesViewModel.isSearchMode {
//                            currentSearchTask?.cancel()
//                            currentSearchTask = nil
//                            Task { await filesViewModel.clearSearch() }
//                        }
//                    }
//
//                if filesViewModel.isSearching {
//                    ProgressView()
//                        .scaleEffect(0.7)
//                        .frame(width: 16, height: 16)
//                } else {
//                    Button { triggerSearch() } label: {
//                        Image(systemName: "magnifyingglass")
//                    }
//                    .help("Search Files")
//                    .disabled(searchText.count < 3)
//                }
//
//                if filesViewModel.isSearchMode {
//                    Button {
//                        searchText = ""
//                        currentSearchTask?.cancel()
//                        currentSearchTask = nil
//                        Task { await filesViewModel.clearSearch() }
//                    } label: {
//                        Image(systemName: "xmark.circle.fill")
//                    }
//                    .buttonStyle(.plain)
//                    .help("Clear Search")
//                }
//            }
        }
        .padding()
    }

    private func triggerSearch() {
        guard filesViewModel.searchText.count >= 3 else { return }
        currentSearchTask?.cancel()
        currentSearchTask = Task {
            await filesViewModel.search(query: filesViewModel.searchText)
        }
    }

    private func upload(urls: [URL], to targetDirectory: FileItem) {
        guard canUpload(to: targetDirectory) else { return }
        for url in urls {
            let accessStarted = url.startAccessingSecurityScopedResource()
            let localPath = url.path
            if let transfer = transfers.uploadTransfer(localPath, toDirectory: targetDirectory, with: connectionID, filesViewModel: filesViewModel) {
                transfers.onTransferTerminal(id: transfer.id) { terminal in
                    guard terminal.type == .upload else { return }
                    guard terminal.state == .stopped || terminal.state == .disconnected else { return }
                    let lowered = terminal.error.lowercased()
                    guard lowered.contains("wired.error.file_exists") || lowered.contains("file_exists") || lowered.contains("already exists") else { return }
                    let conflict = UploadConflict(
                        localPath: terminal.localPath ?? localPath,
                        remotePath: terminal.remotePath ?? targetDirectory.path.stringByAppendingPathComponent(path: (localPath as NSString).lastPathComponent)
                    )
                    DispatchQueue.main.async {
                        enqueueUploadConflict(conflict)
                    }
                }
            }
            if accessStarted {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    private func moveRemoteItem(from sourcePath: String, to destinationDirectory: FileItem) async throws {
        try await filesViewModel.moveRemoteItem(from: sourcePath, to: destinationDirectory.path)
    }

    private func requestDelete(_ items: [FileItem]) {
        let unique = sanitizedDeleteSelection(from: uniqueItems(items).filter { canDelete(item: $0) })
        guard !unique.isEmpty else { return }
        pendingDeleteItems = unique
        showDeleteSelectionConfirmation = true
    }

    private func download(_ items: [FileItem]) {
        let unique = uniqueItems(items)
        pendingDownloadItems = unique.filter { canDownload(item: $0) }
        processPendingDownloads()
    }

    @MainActor
    private func askOverwrite(path: String) -> Bool {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "File Already Exists"
        alert.informativeText = "A file already exists at:\n\(path)\n\nOverwrite it?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Stop")
        return alert.runModal() == .alertFirstButtonReturn
        #else
        return false
        #endif
    }

    private func processPendingDownloads() {
        while !pendingDownloadItems.isEmpty {
            let item = pendingDownloadItems.removeFirst()
            switch transfers.queueDownload(item, with: connectionID, overwriteExistingFile: false) {
            case let .started(transfer), let .resumed(transfer):
                registerDownloadTerminalErrorHook(for: transfer, item: item)
                continue
            case let .needsOverwrite(destination):
                if askOverwrite(path: destination) {
                    switch transfers.queueDownload(item, with: connectionID, overwriteExistingFile: true) {
                    case let .started(transfer), let .resumed(transfer):
                        registerDownloadTerminalErrorHook(for: transfer, item: item)
                    default:
                        break
                    }
                }
                continue
            case .failed:
                continue
            }
        }
    }

    private func registerDownloadTerminalErrorHook(for transfer: Transfer, item: FileItem) {
        transfers.onTransferTerminal(id: transfer.id) { terminal in
            guard terminal.type == .download else { return }
            guard terminal.state == .stopped || terminal.state == .disconnected else { return }

            let message = terminal.error.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }

            DispatchQueue.main.async {
                filesViewModel.error = WiredError(
                    withTitle: "Download Error",
                    message: "Impossible de télécharger \"\(item.name)\":\n\(message)"
                )
            }
        }
    }

    private func enqueueUploadConflict(_ conflict: UploadConflict) {
        if activeUploadConflict?.remotePath == conflict.remotePath {
            return
        }
        if pendingUploadConflicts.contains(where: { $0.remotePath == conflict.remotePath }) {
            return
        }
        pendingUploadConflicts.append(conflict)
        processPendingUploadConflicts()
    }

    private func processPendingUploadConflicts() {
        if activeUploadConflict != nil {
            activeUploadConflict = nil
        }
        guard !pendingUploadConflicts.isEmpty else { return }
        activeUploadConflict = pendingUploadConflicts.removeFirst()
    }

    private func uniqueItems(_ items: [FileItem]) -> [FileItem] {
        var seen: Set<String> = []
        var unique: [FileItem] = []
        for item in items {
            guard !seen.contains(item.path) else { continue }
            seen.insert(item.path)
            unique.append(item)
        }
        return unique
    }

    private func sanitizedDeleteSelection(from items: [FileItem]) -> [FileItem] {
        let normalizedByPath = Dictionary(uniqueKeysWithValues: items.map { (normalizedRemotePath($0.path), $0) })
        let allPaths = Set(normalizedByPath.keys)

        return items.filter { item in
            let candidate = normalizedRemotePath(item.path)
            return !allPaths.contains { other in
                guard other != candidate else { return false }
                return isAncestorPath(candidate, of: other)
            }
        }
    }

    private func isAncestorPath(_ ancestor: String, of descendant: String) -> Bool {
        let normalizedAncestor = normalizedRemotePath(ancestor)
        let normalizedDescendant = normalizedRemotePath(descendant)

        guard normalizedAncestor != normalizedDescendant else { return false }
        if normalizedAncestor == "/" {
            return normalizedDescendant != "/"
        }
        return normalizedDescendant.hasPrefix(normalizedAncestor + "/")
    }

    private func normalizedRemotePath(_ path: String) -> String {
        if path == "/" { return "/" }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "/" }
        return "/" + trimmed
    }

    private func directoryPath(from path: String?) -> String? {
        guard let path else { return nil }
        if let item = itemForPath(path) {
            if item.type.isDirectoryLike {
                return normalizedRemotePath(item.path)
            }
            return normalizedRemotePath(item.path.stringByDeletingLastPathComponent)
        }
        if path == "/" {
            return "/"
        }
        return normalizedRemotePath(path.stringByDeletingLastPathComponent)
    }

    private func registerNavigation(fromPrimarySelectionPath path: String?) {
        guard let directory = directoryPath(from: path) else { return }
        registerNavigation(toDirectoryPath: directory)
    }

    private func registerNavigation(toDirectoryPath path: String) {
        let normalized = normalizedRemotePath(path)
        if normalized == currentDirectoryPath { return }
        if !isApplyingHistoryNavigation {
            backDirectoryHistory.append(currentDirectoryPath)
            forwardDirectoryHistory.removeAll()
        }
        currentDirectoryPath = normalized
    }

    @MainActor
    private func applyHistoryNavigation(to directoryPath: String) async {
        let normalized = normalizedRemotePath(directoryPath)
        switch filesViewModel.selectedFileViewType {
        case .columns:
            let didReveal = await filesViewModel.revealRemotePath(normalized)
            if didReveal, normalized != "/",
               let columnIndex = filesViewModel.columns.indices.last,
               let selectedID = filesViewModel.columns[columnIndex].selection {
                filesViewModel.selectColumnItem(
                    id: selectedID,
                    at: columnIndex,
                    onColumnAppended: { _ in }
                )
            }
            updatePrimarySelectionPath(normalized)
        case .tree:
            _ = await filesViewModel.setTreeRoot(normalized)
            updatePrimarySelectionPath(normalized)
        }
    }

    @MainActor
    private func navigateHistory(backward: Bool) async {
        if filesViewModel.isSearchMode {
            currentSearchTask?.cancel()
            currentSearchTask = nil
            filesViewModel.searchText = ""
            await filesViewModel.clearSearch()
        }

        if backward {
            guard let previous = backDirectoryHistory.popLast() else { return }
            forwardDirectoryHistory.append(currentDirectoryPath)
            isApplyingHistoryNavigation = true
            defer { isApplyingHistoryNavigation = false }
            await applyHistoryNavigation(to: previous)
            currentDirectoryPath = normalizedRemotePath(previous)
            return
        }

        guard let next = forwardDirectoryHistory.popLast() else { return }
        backDirectoryHistory.append(currentDirectoryPath)
        isApplyingHistoryNavigation = true
        defer { isApplyingHistoryNavigation = false }
        await applyHistoryNavigation(to: next)
        currentDirectoryPath = normalizedRemotePath(next)
    }

    private func presentInfo(for item: FileItem) {
        guard canGetInfo(for: item) else { return }
        infoSheetItem = item
    }
}

struct FilesTreeView: View {
    let connectionID: UUID
    @ObservedObject var filesViewModel: FilesViewModel
    @EnvironmentObject private var transfers: TransferManager
    @Environment(\.colorScheme) private var colorScheme

    let onRequestCreateFolder: (FileItem) -> Void
    let onPrimarySelectionChange: (String?) -> Void
    let onSelectionItemsChange: ([FileItem]) -> Void
    let onOpenDirectory: (FileItem) -> Void
    let onRequestUploadInDirectory: (FileItem) -> Void
    let onRequestDeleteSelection: ([FileItem]) -> Void
    let onRequestDownloadSelection: ([FileItem]) -> Void
    let onRequestGetInfo: (FileItem) -> Void
    let onRequestSyncNow: (FileItem) -> Void
    let onRequestActivateSync: (FileItem) -> Void
    let onRequestDeactivateSync: (FileItem) -> Void
    let syncPairStatusForItem: (FileItem) -> SyncPairStatusDisplay
    let syncPairExistsForItem: (FileItem) -> Bool
    let syncPairStatusVersion: Int
    let canSetFileType: Bool
    let canGetInfoForItem: (FileItem) -> Bool
    let canDownloadForItem: (FileItem) -> Bool
    let canDeleteForItem: (FileItem) -> Bool
    let canUploadToDirectory: (FileItem) -> Bool
    let canCreateFolderInDirectory: (FileItem) -> Bool
    let onUploadURLs: ([URL], FileItem) -> Void
    let onMoveRemoteItem: (_ sourcePath: String, _ destinationDirectory: FileItem) async throws -> Void
    @State private var finderDropTargetPath: String?
    @State private var selectedPaths: Set<String> = []

    var body: some View {
        #if os(macOS)
        AppKitFilesTreeView(
            rootPath: filesViewModel.treeRootPath,
            treeChildrenByPath: filesViewModel.treeChildrenByPath,
            expandedPaths: filesViewModel.expandedTreePaths,
            connectionID: connectionID,
            transferManager: transfers,
            onDownloadTransferError: { item, message in
                filesViewModel.error = WiredError(
                    withTitle: "Download Error",
                    message: "Impossible de télécharger \"\(item.name)\":\n\(message)"
                )
            },
            onUploadURLs: onUploadURLs,
            selectedPaths: $selectedPaths,
            onSelectionChange: { newSelection in
                let orderedNodes = filesViewModel.visibleTreeNodes()
                let orderedPaths = orderedNodes.map { $0.item.path }
                let primaryPath = orderedPaths.first(where: { newSelection.contains($0) })
                onPrimarySelectionChange(primaryPath)
                onSelectionItemsChange(selectedItems(from: newSelection))

                if let primaryPath {
                    filesViewModel.treeSelectionPath = primaryPath
                } else {
                    filesViewModel.treeSelectionPath = nil
                }
            },
            onSetDirectoryExpanded: { path, expanded in
                Task { await filesViewModel.setTreeExpansion(for: path, expanded: expanded) }
            },
            onDownloadSingleFile: { item in
                guard canDownloadForItem(item) else { return }
                onRequestDownloadSelection([item])
            },
            onOpenDirectory: { directory in
                onOpenDirectory(directory)
            },
            onRequestCreateFolder: {
                let target = contextMenuTargetDirectory()
                guard canCreateFolderInDirectory(target) else { return }
                onRequestCreateFolder(target)
            },
            onRequestUploadInDirectory: { directory in
                guard canUploadToDirectory(directory) else { return }
                onRequestUploadInDirectory(directory)
            },
            onRequestDeleteSelection: {
                let selected = selectedItems(from: selectedPaths)
                guard !selected.isEmpty else { return }
                let deletable = selected.filter { canDeleteForItem($0) }
                guard !deletable.isEmpty else { return }
                onRequestDeleteSelection(deletable)
            },
            onRequestDownloadSelection: {
                let selected = selectedItems(from: selectedPaths)
                guard !selected.isEmpty else { return }
                let downloadable = selected.filter { canDownloadForItem($0) }
                guard !downloadable.isEmpty else { return }
                onRequestDownloadSelection(downloadable)
            },
            onRequestGetInfo: { item in
                guard canGetInfoForItem(item) else { return }
                onRequestGetInfo(item)
            },
            onRequestSyncNow: { item in
                guard item.type == .sync else { return }
                onRequestSyncNow(item)
            },
            onRequestActivateSync: { item in
                guard item.type == .sync else { return }
                onRequestActivateSync(item)
            },
            onRequestDeactivateSync: { item in
                guard item.type == .sync else { return }
                onRequestDeactivateSync(item)
            },
            syncPairStatusForPath: { path in
                // The caller (cell renderer) already guards on item.type == .sync before
                // invoking this closure, so constructing a minimal FileItem is safe here.
                return syncPairStatusForItem(FileItem("", path: path, type: .sync))
            },
            syncPairExistsForPath: { path in
                syncPairExistsForItem(FileItem("", path: path, type: .sync))
            },
            syncPairStatusVersion: syncPairStatusVersion,
            canSetFileType: canSetFileType,
            canGetInfoForItem: canGetInfoForItem,
            canDownloadForItem: canDownloadForItem,
            canDeleteForItem: canDeleteForItem,
            canUploadToDirectory: canUploadToDirectory,
            canCreateFolderInDirectory: canCreateFolderInDirectory,
            savedScrollOffset: filesViewModel.treeScrollOffset,
            onScrollOffsetChange: { filesViewModel.treeScrollOffset = $0 }
        )
        .background(colorScheme == .light ? Color.white : Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !filesViewModel.isSearchMode {
                Task { await filesViewModel.loadTreeRoot() }
            }
            selectedPaths = Set([filesViewModel.treeSelectionPath].compactMap { $0 })
        }
        .onChange(of: filesViewModel.treeSelectionPath) { _, newValue in
            if selectedPaths.count <= 1 {
                selectedPaths = Set([newValue].compactMap { $0 })
            }
        }
        #else
        EmptyView()
        #endif
    }

    private func selectedItems(from paths: Set<String>) -> [FileItem] {
        let byPath = Dictionary(uniqueKeysWithValues: filesViewModel.visibleTreeNodes().map { ($0.item.path, $0.item) })
        return paths.compactMap { byPath[$0] }
    }

    private func contextMenuTargetDirectory() -> FileItem {
        if let selected = filesViewModel.selectedTreeItem() {
            if selected.type.isDirectoryLike {
                return selected
            }

            let parentPath = selected.path.stringByDeletingLastPathComponent
            return FileItem(parentPath.lastPathComponent, path: parentPath, type: .directory)
        }

        let root = filesViewModel.treeRootPath
        let rootName = root == "/" ? "/" : (root as NSString).lastPathComponent
        return FileItem(rootName, path: root, type: .directory)
    }

}

#if os(macOS)
private var dragPromiseDelegateAssociationKey: UInt8 = 0

private final class FinderDropSecurityScopeBroker {
    static let shared = FinderDropSecurityScopeBroker()

    private let lock = NSLock()
    private var scopedURLs: [UUID: [URL]] = [:]

    private init() {}

    @discardableResult
    func retainScope(for transferID: UUID, at url: URL) -> Bool {
        let didAccess = url.startAccessingSecurityScopedResource()
        guard didAccess else { return false }

        lock.lock()
        var urls = scopedURLs[transferID] ?? []
        if !urls.contains(where: { $0.path == url.path }) {
            urls.append(url)
        }
        scopedURLs[transferID] = urls
        lock.unlock()
        return true
    }

    func releaseScope(for transferID: UUID) {
        lock.lock()
        let urls = scopedURLs.removeValue(forKey: transferID) ?? []
        lock.unlock()
        for url in urls {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

private struct AppKitFilesTreeView: NSViewRepresentable {
    let rootPath: String
    let treeChildrenByPath: [String: [FileItem]]
    let expandedPaths: Set<String>
    let connectionID: UUID
    let transferManager: TransferManager
    let onDownloadTransferError: (FileItem, String) -> Void
    let onUploadURLs: ([URL], FileItem) -> Void
    @Binding var selectedPaths: Set<String>
    let onSelectionChange: (Set<String>) -> Void
    let onSetDirectoryExpanded: (String, Bool) -> Void
    let onDownloadSingleFile: (FileItem) -> Void
    let onOpenDirectory: (FileItem) -> Void
    let onRequestCreateFolder: () -> Void
    let onRequestUploadInDirectory: (FileItem) -> Void
    let onRequestDeleteSelection: () -> Void
    let onRequestDownloadSelection: () -> Void
    let onRequestGetInfo: (FileItem) -> Void
    let onRequestSyncNow: (FileItem) -> Void
    let onRequestActivateSync: (FileItem) -> Void
    let onRequestDeactivateSync: (FileItem) -> Void
    let syncPairStatusForPath: (String) -> SyncPairStatusDisplay
    let syncPairExistsForPath: (String) -> Bool
    let syncPairStatusVersion: Int
    let canSetFileType: Bool
    let canGetInfoForItem: (FileItem) -> Bool
    let canDownloadForItem: (FileItem) -> Bool
    let canDeleteForItem: (FileItem) -> Bool
    let canUploadToDirectory: (FileItem) -> Bool
    let canCreateFolderInDirectory: (FileItem) -> Bool
    let savedScrollOffset: CGPoint
    let onScrollOffsetChange: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let outlineView = NSOutlineView()
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.backgroundColor = .clear
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.rowHeight = 26
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.doubleAction = #selector(Coordinator.didDoubleClick(_:))
        outlineView.target = context.coordinator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TreeColumn"))
        column.title = "Name"
        column.minWidth = 220
        column.width = 420
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SizeColumn"))
        sizeColumn.title = "Size"
        sizeColumn.minWidth = 90
        sizeColumn.width = 120
        sizeColumn.resizingMask = []
        outlineView.addTableColumn(sizeColumn)

        outlineView.delegate = context.coordinator
        outlineView.dataSource = context.coordinator
        let menu = context.coordinator.makeContextMenu()
        menu.delegate = context.coordinator
        outlineView.menu = menu

        scrollView.documentView = outlineView
        context.coordinator.outlineView = outlineView
        context.coordinator.scrollView = scrollView
        context.coordinator.syncFromModel(
            rootPath: rootPath,
            childrenByPath: treeChildrenByPath,
            expandedPaths: expandedPaths,
            selectedPaths: selectedPaths,
            syncPairStatusVersion: syncPairStatusVersion
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleScrollChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        let offsetToRestore = savedScrollOffset
        DispatchQueue.main.async {
            scrollView.contentView.scroll(to: offsetToRestore)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncFromModel(
            rootPath: rootPath,
            childrenByPath: treeChildrenByPath,
            expandedPaths: expandedPaths,
            selectedPaths: selectedPaths,
            syncPairStatusVersion: syncPairStatusVersion
        )
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        final class OutlineNode: NSObject {
            let item: FileItem
            var children: [OutlineNode] = []

            init(item: FileItem) {
                self.item = item
            }
        }

        var parent: AppKitFilesTreeView
        weak var outlineView: NSOutlineView?
        weak var scrollView: NSScrollView?
        private let rootNode = OutlineNode(item: FileItem("/", path: "/", type: .directory))
        private var nodesByPath: [String: OutlineNode] = [:]
        private var currentRootPath: String = "/"
        private var isApplyingSelectionFromSwiftUI = false
        private var isApplyingExpandedStateFromSwiftUI = false
        private var suppressDisclosureCallbacks = false
        private var pendingExpansionState: [String: Bool] = [:]
        private var contextDirectoryTarget: FileItem = FileItem("/", path: "/", type: .directory)
        private var contextSyncTarget: FileItem?
        private var clickedRowHadSelection = false
        /// Path structure snapshot used to detect tree data changes vs. sync-status-only changes.
        private var lastChildrenPaths: [String: [String]] = [:]
        private var lastSyncPairStatusVersion: Int = -1

        init(parent: AppKitFilesTreeView) {
            self.parent = parent
            self.currentRootPath = parent.rootPath
            let normalizedRoot: String = {
                if parent.rootPath == "/" { return "/" }
                let trimmed = parent.rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return trimmed.isEmpty ? "/" : "/" + trimmed
            }()
            let rootName = normalizedRoot == "/" ? "/" : (normalizedRoot as NSString).lastPathComponent
            self.contextDirectoryTarget = FileItem(rootName, path: normalizedRoot, type: .directory)
        }

        @objc func handleScrollChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            parent.onScrollOffsetChange(sv.contentView.bounds.origin)
        }

        private func isDirectory(_ item: FileItem) -> Bool {
            item.type.isDirectoryLike
        }

        private func sortedItems(_ items: [FileItem]) -> [FileItem] {
            items.sorted {
                let lhsDir = isDirectory($0)
                let rhsDir = isDirectory($1)
                if lhsDir != rhsDir { return lhsDir }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        private func fileSizeString(_ item: FileItem) -> String {
            guard item.type == .file else { return "-" }
            let total = Int64(item.dataSize + item.rsrcSize)
            return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        }

        private func ancestorPaths(for path: String) -> [String] {
            var result: [String] = []
            var current = (path as NSString).deletingLastPathComponent
            while !current.isEmpty && current != "/" {
                result.append(current)
                current = (current as NSString).deletingLastPathComponent
            }
            result.append("/")
            return result
        }

        private func ensureExpandedAncestors(in expanded: inout Set<String>) {
            let snapshot = Array(expanded)
            for path in snapshot {
                for ancestor in ancestorPaths(for: path) {
                    expanded.insert(ancestor)
                }
            }
        }

        private func treeDepth(for path: String) -> Int {
            if path == "/" { return 0 }
            return path.split(separator: "/").count
        }

        private func normalizedRemotePath(_ path: String) -> String {
            if path == "/" { return "/" }
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if trimmed.isEmpty { return "/" }
            return "/" + trimmed
        }

        private func directoryItem(for path: String) -> FileItem {
            let normalized = normalizedRemotePath(path)
            let name = normalized == "/" ? "/" : (normalized as NSString).lastPathComponent
            return FileItem(name, path: normalized, type: .directory)
        }

        func refreshTree(rootPath: String, childrenByPath: [String: [FileItem]]) {
            lastChildrenPaths = childrenByPath.mapValues { $0.map(\.path) }
            nodesByPath.removeAll()
            currentRootPath = normalizedRemotePath(rootPath)

            func node(for item: FileItem) -> OutlineNode {
                if let existing = nodesByPath[item.path] { return existing }
                let created = OutlineNode(item: item)
                nodesByPath[item.path] = created
                return created
            }

            func buildChildren(parentPath: String, visiting: inout Set<String>) -> [OutlineNode] {
                guard !visiting.contains(parentPath) else { return [] }
                visiting.insert(parentPath)
                defer { visiting.remove(parentPath) }

                let children = sortedItems(childrenByPath[parentPath] ?? [])
                return children.map { childItem in
                    let childNode = node(for: childItem)
                    if isDirectory(childItem), childrenByPath[childItem.path] != nil {
                        childNode.children = buildChildren(parentPath: childItem.path, visiting: &visiting)
                    } else {
                        childNode.children = []
                    }
                    return childNode
                }
            }

            var visiting: Set<String> = []
            rootNode.children = buildChildren(parentPath: currentRootPath, visiting: &visiting)
            outlineView?.reloadData()
        }

        func syncFromModel(
            rootPath: String,
            childrenByPath: [String: [FileItem]],
            expandedPaths: Set<String>,
            selectedPaths: Set<String>,
            syncPairStatusVersion: Int
        ) {
            // Drop pending entries once model caught up to user-driven disclosure changes.
            for (path, desiredExpanded) in pendingExpansionState {
                let modelExpanded = expandedPaths.contains(path)
                if modelExpanded == desiredExpanded {
                    pendingExpansionState.removeValue(forKey: path)
                }
            }

            var effectiveExpandedPaths = expandedPaths
            for (path, desiredExpanded) in pendingExpansionState {
                if desiredExpanded {
                    effectiveExpandedPaths.insert(path)
                } else {
                    effectiveExpandedPaths.remove(path)
                }
            }
            ensureExpandedAncestors(in: &effectiveExpandedPaths)

            suppressDisclosureCallbacks = true
            defer { suppressDisclosureCallbacks = false }

            let newRoot = normalizedRemotePath(rootPath)
            let treeChanged = newRoot != currentRootPath || treeStructureDidChange(childrenByPath)
            let syncStatusChanged = syncPairStatusVersion != lastSyncPairStatusVersion
            if treeChanged {
                refreshTree(rootPath: rootPath, childrenByPath: childrenByPath)
            } else if syncStatusChanged {
                // Tree structure is unchanged; only sync-pair status may have changed.
                // Reload just the .sync nodes to update their indicators.
                refreshSyncIndicators()
            }
            lastSyncPairStatusVersion = syncPairStatusVersion
            applyExpandedState(effectiveExpandedPaths)
            updateSelection(selectedPaths)
        }

        /// Returns true when the path-level structure of the tree differs from the last known snapshot.
        private func treeStructureDidChange(_ newChildren: [String: [FileItem]]) -> Bool {
            guard newChildren.count == lastChildrenPaths.count else { return true }
            for (key, items) in newChildren {
                guard let cached = lastChildrenPaths[key], cached == items.map(\.path) else { return true }
            }
            return false
        }

        /// Reloads only the visible .sync nodes to refresh their pair-status indicators.
        private func refreshSyncIndicators() {
            guard let outlineView else { return }
            for node in nodesByPath.values where node.item.type == .sync {
                outlineView.reloadItem(node, reloadChildren: false)
            }
        }

        func applyExpandedState(_ expandedPaths: Set<String>) {
            guard let outlineView else { return }
            isApplyingExpandedStateFromSwiftUI = true
            defer { isApplyingExpandedStateFromSwiftUI = false }

            let expandableNodes = nodesByPath.values
                .filter { isDirectory($0.item) }
                .sorted {
                    let lhsDepth = treeDepth(for: $0.item.path)
                    let rhsDepth = treeDepth(for: $1.item.path)
                    if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                    return $0.item.path < $1.item.path
                }

            for node in expandableNodes {
                let path = node.item.path
                if expandedPaths.contains(path), !outlineView.isItemExpanded(node) {
                    outlineView.expandItem(node, expandChildren: false)
                }
            }

            for node in expandableNodes.reversed() {
                let path = node.item.path
                if !expandedPaths.contains(path), outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node, collapseChildren: false)
                }
            }
        }

        func updateSelection(_ selectedPaths: Set<String>) {
            guard let outlineView else { return }
            var indexSet = IndexSet()
            for path in selectedPaths {
                guard let node = nodesByPath[path] else { continue }
                let row = outlineView.row(forItem: node)
                if row >= 0 {
                    indexSet.insert(row)
                }
            }
            if outlineView.selectedRowIndexes != indexSet {
                isApplyingSelectionFromSwiftUI = true
                outlineView.selectRowIndexes(indexSet, byExtendingSelection: false)
                isApplyingSelectionFromSwiftUI = false
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            let node = (item as? OutlineNode) ?? rootNode
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            let node = (item as? OutlineNode) ?? rootNode
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? OutlineNode else { return false }
            return isDirectory(node.item)
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? OutlineNode else { return nil }
            let item = node.item
            let columnID = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("TreeColumn")

            if columnID == NSUserInterfaceItemIdentifier("SizeColumn") {
                let id = NSUserInterfaceItemIdentifier("TreeSizeCell")
                let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                    let cell = NSTableCellView()
                    cell.identifier = id
                    let tf = NSTextField(labelWithString: "")
                    tf.translatesAutoresizingMaskIntoConstraints = false
                    tf.alignment = .right
                    tf.textColor = .secondaryLabelColor
                    tf.lineBreakMode = .byClipping
                    cell.addSubview(tf)
                    cell.textField = tf
                    NSLayoutConstraint.activate([
                        tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                        tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                        tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                    return cell
                }()
                cell.textField?.stringValue = fileSizeString(item)
                return cell
            }

            let id = NSUserInterfaceItemIdentifier("TreeCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.imageScaling = .scaleProportionallyUpOrDown
                cell.imageView = icon

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(tf)
                cell.textField = tf
                cell.addSubview(icon)

                let statusIcon = NSImageView()
                statusIcon.identifier = NSUserInterfaceItemIdentifier("SyncStatusIcon")
                statusIcon.translatesAutoresizingMaskIntoConstraints = false
                statusIcon.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(statusIcon)

                let statusSpinner = NSProgressIndicator()
                statusSpinner.identifier = NSUserInterfaceItemIdentifier("SyncStatusSpinner")
                statusSpinner.translatesAutoresizingMaskIntoConstraints = false
                statusSpinner.controlSize = .regular
                statusSpinner.style = .spinning
                statusSpinner.isDisplayedWhenStopped = false
                cell.addSubview(statusSpinner)

                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: statusIcon.leadingAnchor, constant: -6),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: statusSpinner.leadingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusIcon.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    statusIcon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusIcon.widthAnchor.constraint(equalToConstant: 16),
                    statusIcon.heightAnchor.constraint(equalToConstant: 16),
                    statusSpinner.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    statusSpinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusSpinner.widthAnchor.constraint(equalToConstant: 16),
                    statusSpinner.heightAnchor.constraint(equalToConstant: 16)
                ])
                return cell
            }()
            cell.textField?.stringValue = item.name
            cell.imageView?.image = remoteItemIconImage(for: item, size: 16)

            let statusIcon = cell.subviews.compactMap { $0 as? NSImageView }
                .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("SyncStatusIcon") })
            let statusSpinner = cell.subviews.compactMap { $0 as? NSProgressIndicator }
                .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("SyncStatusSpinner") })
            // Only query sync status for .sync items; non-sync items always hide the indicator.
            let syncStatus: SyncPairStatusDisplay = item.type == .sync
                ? parent.syncPairStatusForPath(item.path)
                : .hidden
            switch syncStatus {
            case .hidden:
                statusIcon?.isHidden = true
                statusSpinner?.stopAnimation(nil)
            case .checking:
                statusIcon?.isHidden = true
                statusSpinner?.isHidden = false
                statusSpinner?.startAnimation(nil)
            case .active:
                statusSpinner?.stopAnimation(nil)
                statusIcon?.isHidden = false
                statusIcon?.contentTintColor = .systemGreen
                statusIcon?.image = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: "Pair active")
            case .inactive:
                statusSpinner?.stopAnimation(nil)
                statusIcon?.isHidden = false
                statusIcon?.contentTintColor = .secondaryLabelColor
                statusIcon?.image = NSImage(systemSymbolName: "link.circle", accessibilityDescription: "Pair inactive")
            }
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            if isApplyingSelectionFromSwiftUI { return }
            guard let outlineView else { return }
            var paths = Set<String>()
            for idx in outlineView.selectedRowIndexes {
                guard idx >= 0,
                      let node = outlineView.item(atRow: idx) as? OutlineNode else { continue }
                paths.insert(node.item.path)
            }
            parent.selectedPaths = paths
            parent.onSelectionChange(paths)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if isApplyingExpandedStateFromSwiftUI || suppressDisclosureCallbacks { return }
            guard let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
            pendingExpansionState[node.item.path] = true
            for ancestor in ancestorPaths(for: node.item.path) {
                pendingExpansionState[ancestor] = true
            }
            DispatchQueue.main.async {
                self.parent.onSetDirectoryExpanded(node.item.path, true)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if isApplyingExpandedStateFromSwiftUI || suppressDisclosureCallbacks { return }
            guard let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
            pendingExpansionState[node.item.path] = false
            let prefix = node.item.path == "/" ? "/" : node.item.path + "/"
            for (key, _) in pendingExpansionState where key.hasPrefix(prefix) {
                pendingExpansionState[key] = false
            }
            DispatchQueue.main.async {
                self.parent.onSetDirectoryExpanded(node.item.path, false)
            }
        }

        @objc
        func didDoubleClick(_ sender: Any?) {
            guard let outlineView else { return }
            let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
            guard row >= 0, let node = outlineView.item(atRow: row) as? OutlineNode else { return }
            let item = node.item
            let isDir = isDirectory(item)
            if isDir {
                parent.onOpenDirectory(item)
            } else if parent.canDownloadForItem(item) {
                parent.onDownloadSingleFile(item)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem itemRef: Any) -> NSPasteboardWriting? {
            guard let node = itemRef as? OutlineNode else { return nil }
            let item = node.item
            let isDir = isDirectory(item)
            let fileType: String
            if isDir {
                fileType = UTType.folder.identifier
            } else {
                let ext = (dragExportFileName(for: item) as NSString).pathExtension
                fileType = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
            }

            let delegate = DragPlaceholderPromiseDelegate(item: item)
            delegate.connectionID = parent.connectionID
            delegate.transferManager = parent.transferManager
            delegate.onDownloadTransferError = parent.onDownloadTransferError
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: delegate)
            // NSFilePromiseProvider's delegate is weak in practice for drag lifetime.
            // Retain it through associated storage to guarantee writePromiseTo callback.
            objc_setAssociatedObject(
                provider,
                &dragPromiseDelegateAssociationKey,
                delegate,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            return provider
        }

        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        private func finderDroppedURLs(from info: NSDraggingInfo) -> [URL] {
            let classes: [AnyClass] = [NSURL.self]
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            return info.draggingPasteboard.readObjects(forClasses: classes, options: options) as? [URL] ?? []
        }

        private func dropDestination(for itemRef: Any?) -> FileItem? {
            guard let node = itemRef as? OutlineNode else {
                return directoryItem(for: currentRootPath)
            }

            let item = node.item
            guard isDirectory(item) else { return nil }
            return item
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let urls = finderDroppedURLs(from: info)
            guard !urls.isEmpty else { return [] }
            guard let destination = dropDestination(for: item) else { return [] }

            if item == nil || destination.path == currentRootPath {
                outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            } else {
                outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            }
            return .copy
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let urls = finderDroppedURLs(from: info)
            guard !urls.isEmpty else { return false }
            guard let destination = dropDestination(for: item) else { return false }

            DispatchQueue.main.async {
                self.parent.onUploadURLs(urls, destination)
            }
            return true
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(withTitle: "Download", action: #selector(contextDownload), keyEquivalent: "")
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            menu.addItem(withTitle: "Upload…", action: #selector(contextUpload), keyEquivalent: "")
            menu.addItem(withTitle: "Get Info", action: #selector(contextGetInfo), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            let statusItem = menu.addItem(withTitle: "Sync Status: Pair inactive", action: nil, keyEquivalent: "")
            statusItem.tag = SyncContextMenuItemTag.status
            let toggleItem = menu.addItem(withTitle: "Activate Sync Pair", action: #selector(contextToggleSyncPair), keyEquivalent: "")
            toggleItem.tag = SyncContextMenuItemTag.toggle
            let syncNowItem = menu.addItem(withTitle: "Sync Now", action: #selector(contextSyncNow), keyEquivalent: "")
            syncNowItem.tag = SyncContextMenuItemTag.syncNow
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "New Folder", action: #selector(contextNewFolder), keyEquivalent: "")
            for item in menu.items {
                item.target = self
            }
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let outlineView else { return }
            let point = outlineView.convert(outlineView.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
            let row = outlineView.row(at: point)
            let hasSelectionBefore = !outlineView.selectedRowIndexes.isEmpty

            if row >= 0 {
                clickedRowHadSelection = outlineView.selectedRowIndexes.contains(row)
                if !clickedRowHadSelection {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }

                if let node = outlineView.item(atRow: row) as? OutlineNode {
                    let item = node.item
                    if isDirectory(item) {
                        contextDirectoryTarget = item
                    } else {
                        let parentPath = item.path.stringByDeletingLastPathComponent
                        contextDirectoryTarget = FileItem(parentPath.lastPathComponent, path: parentPath, type: .directory)
                    }
                } else {
                    contextDirectoryTarget = directoryItem(for: currentRootPath)
                }
            } else {
                clickedRowHadSelection = false
                if hasSelectionBefore {
                    outlineView.deselectAll(nil)
                }
                contextDirectoryTarget = directoryItem(for: currentRootPath)
            }

            let selectedRows = outlineView.selectedRowIndexes.compactMap { row -> Int? in
                row >= 0 ? row : nil
            }
            let selectedItems = selectedRows.compactMap { row -> FileItem? in
                (outlineView.item(atRow: row) as? OutlineNode)?.item
            }
            if let downloadItem = menu.item(withTitle: "Download") {
                downloadItem.isEnabled = selectedItems.contains(where: { parent.canDownloadForItem($0) })
            }
            if let deleteItem = menu.item(withTitle: "Delete") {
                deleteItem.isEnabled = selectedItems.contains(where: { parent.canDeleteForItem($0) })
            }
            if let uploadItem = menu.item(withTitle: "Upload…") {
                uploadItem.isEnabled = parent.canUploadToDirectory(contextDirectoryTarget)
            }
            if let infoItem = menu.item(withTitle: "Get Info") {
                let canGetSelectedInfo: Bool = {
                    guard selectedItems.count == 1, let item = selectedItems.first else { return false }
                    return parent.canGetInfoForItem(item)
                }()
                infoItem.isEnabled = canGetSelectedInfo
            }
            let selectedSyncItem: FileItem? = {
                guard selectedItems.count == 1, let item = selectedItems.first, item.type == .sync else { return nil }
                return item
            }()
            contextSyncTarget = selectedSyncItem
            let syncState: SyncPairStatusDisplay = selectedSyncItem.map { parent.syncPairStatusForPath($0.path) } ?? .hidden
            let pairExists = selectedSyncItem.map { parent.syncPairExistsForPath($0.path) } ?? false

            if let syncStatusItem = menu.item(withTag: SyncContextMenuItemTag.status) {
                switch syncState {
                case .active:
                    syncStatusItem.title = "Sync Status: Pair active"
                case .inactive:
                    syncStatusItem.title = "Sync Status: Pair inactive"
                case .checking:
                    syncStatusItem.title = "Sync Status: Updating…"
                case .hidden:
                    syncStatusItem.title = "Sync Status: Pair inactive"
                }
                syncStatusItem.isHidden = selectedSyncItem == nil
                syncStatusItem.isEnabled = false
            }

            if let toggleItem = menu.item(withTag: SyncContextMenuItemTag.toggle) {
                if selectedSyncItem == nil {
                    toggleItem.title = "Activate Sync Pair"
                    toggleItem.isEnabled = false
                } else if syncState == .checking {
                    toggleItem.title = pairExists ? "Deactivate Sync Pair" : "Activate Sync Pair"
                    toggleItem.isEnabled = false
                } else if pairExists {
                    toggleItem.title = "Deactivate Sync Pair"
                    toggleItem.isEnabled = true
                } else {
                    toggleItem.title = "Activate Sync Pair"
                    toggleItem.isEnabled = true
                }
                toggleItem.isHidden = selectedSyncItem == nil
            }
            if let syncItem = menu.item(withTag: SyncContextMenuItemTag.syncNow) {
                let canSyncNow = selectedSyncItem != nil && pairExists && syncState != .checking
                syncItem.isHidden = selectedSyncItem == nil
                syncItem.isEnabled = canSyncNow
            }
            if let newFolderItem = menu.item(withTitle: "New Folder") {
                newFolderItem.isEnabled = parent.canCreateFolderInDirectory(contextDirectoryTarget)
            }
        }

        @objc private func contextDownload() { parent.onRequestDownloadSelection() }
        @objc private func contextDelete() { parent.onRequestDeleteSelection() }
        @objc private func contextUpload() {
            guard parent.canUploadToDirectory(contextDirectoryTarget) else { return }
            parent.onRequestUploadInDirectory(contextDirectoryTarget)
        }
        @objc private func contextGetInfo() {
            guard let item = contextSyncTarget ?? selectedItem() else { return }
            guard parent.canGetInfoForItem(item) else { return }
            parent.onRequestGetInfo(item)
        }
        @objc private func contextSyncNow() {
            guard let item = contextSyncTarget else { return }
            parent.onRequestSyncNow(item)
        }
        @objc private func contextToggleSyncPair() {
            guard let item = contextSyncTarget, item.type == .sync else { return }
            if parent.syncPairStatusForPath(item.path) == .checking {
                return
            }
            if parent.syncPairExistsForPath(item.path) {
                parent.onRequestDeactivateSync(item)
            } else {
                parent.onRequestActivateSync(item)
            }
        }
        private func selectedItem() -> FileItem? {
            guard let outlineView else { return nil }
            let selectedRows = outlineView.selectedRowIndexes.compactMap { row -> Int? in row >= 0 ? row : nil }
            let selectedItems = selectedRows.compactMap { row -> FileItem? in
                (outlineView.item(atRow: row) as? OutlineNode)?.item
            }
            guard selectedItems.count == 1 else { return nil }
            return selectedItems.first
        }
        @objc private func contextNewFolder() {
            guard parent.canCreateFolderInDirectory(contextDirectoryTarget) else { return }
            parent.onRequestCreateFolder()
        }
    }
}

private final class DragPlaceholderPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let item: FileItem
    private let isDirectory: Bool
    private let fileName: String
    private let partialName: String
    var connectionID: UUID?
    weak var transferManager: TransferManager?
    var onDownloadTransferError: ((FileItem, String) -> Void)?
    private var didStartTransfer = false

    @MainActor
    private func askOverwrite(path: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "File Already Exists"
        alert.informativeText = "Do you want to overwrite \"\(path)\"?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Stop")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func log(_ message: String) {
        NSLog("[WiredTreeDrag] %@", message)
    }

    init(item: FileItem) {
        self.item = item
        self.isDirectory = (item.type.isDirectoryLike)
        self.fileName = dragExportFileName(for: item)
        self.partialName = fileName + ".\(Wired.transfersFileExtension)"
        super.init()
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        isDirectory ? fileName : partialName
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo destinationURL: URL, completionHandler: @escaping (Error?) -> Void) {
        if didStartTransfer {
            completionHandler(nil)
            return
        }
        didStartTransfer = true

        let targetURL: URL = {
            guard !isDirectory else { return destinationURL }
            // Finder may disambiguate promised names ("name 2.WiredTransfer").
            // Force canonical target to support proper resume/overwrite policy.
            return destinationURL
                .deletingLastPathComponent()
                .appendingPathComponent(partialName, isDirectory: false)
        }()
        let fm = FileManager.default
        log("writePromiseTo start path=\(targetURL.path)")

        do {
            if isDirectory {
                if fm.fileExists(atPath: targetURL.path) {
                    try fm.removeItem(at: targetURL)
                }
                try fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            }
            log("placeholder ready path=\(targetURL.path)")

            let completionLock = NSLock()
            var terminalError: Error?
            let done = DispatchSemaphore(value: 0)

            if let connectionID, let transferManager {
                Task { @MainActor in
                    let startedTransfer: Transfer?
                    switch transferManager.queueDownload(item, to: targetURL.path, with: connectionID, overwriteExistingFile: false) {
                    case let .started(transfer), let .resumed(transfer):
                        startedTransfer = transfer
                    case let .needsOverwrite(destination):
                        if self.askOverwrite(path: destination) {
                            switch transferManager.queueDownload(item, to: targetURL.path, with: connectionID, overwriteExistingFile: true) {
                            case let .started(transfer), let .resumed(transfer):
                                startedTransfer = transfer
                            default:
                                startedTransfer = nil
                            }
                        } else {
                            startedTransfer = nil
                        }
                    case .failed:
                        startedTransfer = nil
                    }

                    guard let transfer = startedTransfer else {
                        self.log("downloadTransfer returned nil path=\(targetURL.path)")
                        if self.isDirectory {
                            completionHandler(NSError(
                                domain: "Wired.DragAndDrop",
                                code: 13,
                                userInfo: [NSLocalizedDescriptionKey: "Unable to start folder download transfer."]
                            ))
                        } else {
                            completionLock.withLock {
                                terminalError = NSError(
                                    domain: "Wired.DragAndDrop",
                                    code: 13,
                                    userInfo: [NSLocalizedDescriptionKey: "Unable to start download transfer."]
                                )
                            }
                            done.signal()
                        }
                        return
                    }

                    if !self.isDirectory && !fm.fileExists(atPath: targetURL.path) {
                        guard fm.createFile(atPath: targetURL.path, contents: nil, attributes: nil) else {
                            completionLock.withLock {
                                terminalError = NSError(
                                    domain: "Wired.DragAndDrop",
                                    code: 12,
                                    userInfo: [NSLocalizedDescriptionKey: "Unable to create placeholder file at destination."]
                                )
                            }
                            done.signal()
                            return
                        }
                    }

                    let primaryScope = FinderDropSecurityScopeBroker.shared.retainScope(for: transfer.id, at: targetURL)
                    let parentURL = targetURL.deletingLastPathComponent()
                    let parentScope = FinderDropSecurityScopeBroker.shared.retainScope(for: transfer.id, at: parentURL)
                    self.log("transfer started id=\(transfer.id) scopeTarget=\(targetURL.path) ok=\(primaryScope) scopeParent=\(parentURL.path) ok=\(parentScope)")
                    transferManager.onTransferTerminal(id: transfer.id) { transfer in
                        FinderDropSecurityScopeBroker.shared.releaseScope(for: transfer.id)
                        if self.isDirectory {
                            return
                        }
                        if transfer.state != .finished {
                            let message = transfer.error.isEmpty
                                ? "Transfer ended with state \(transfer.state.rawValue)."
                                : transfer.error
                            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self.onDownloadTransferError?(self.item, message)
                            }
                            completionLock.lock()
                            terminalError = NSError(
                                domain: "Wired.DragAndDrop",
                                code: 14,
                                userInfo: [NSLocalizedDescriptionKey: message]
                            )
                            completionLock.unlock()
                        }
                        done.signal()
                    }

                    if self.isDirectory {
                        completionHandler(nil)
                    }
                }
            } else {
                if isDirectory {
                    completionHandler(NSError(
                        domain: "Wired.DragAndDrop",
                        code: 15,
                        userInfo: [NSLocalizedDescriptionKey: "Missing connection context for folder transfer."]
                    ))
                } else {
                    completionLock.lock()
                    terminalError = NSError(
                        domain: "Wired.DragAndDrop",
                        code: 15,
                        userInfo: [NSLocalizedDescriptionKey: "Missing connection context for transfer."]
                    )
                    completionLock.unlock()
                    done.signal()
                }
            }

            if isDirectory {
                return
            }

            _ = done.wait(timeout: .distantFuture)
            completionLock.lock()
            let error = terminalError
            completionLock.unlock()
            completionHandler(error)
        } catch {
            log("writePromiseTo error path=\(targetURL.path) err=\(error.localizedDescription)")
            completionHandler(error)
        }
    }
}
#endif

struct FilesColumnsView: View {
    let connectionID: UUID

    @ObservedObject var filesViewModel: FilesViewModel
    @EnvironmentObject private var transfers: TransferManager
    @Environment(\.colorScheme) private var colorScheme

    let onRequestCreateFolder: (FileItem) -> Void
    let onPrimarySelectionChange: (String?) -> Void
    let onSelectionItemsChange: ([FileItem]) -> Void
    let onRequestUploadInDirectory: (FileItem) -> Void
    let onRequestDeleteSelection: ([FileItem]) -> Void
    let onRequestDownloadSelection: ([FileItem]) -> Void
    let onRequestGetInfo: (FileItem) -> Void
    let onRequestSyncNow: (FileItem) -> Void
    let onRequestActivateSync: (FileItem) -> Void
    let onRequestDeactivateSync: (FileItem) -> Void
    let syncPairStatusForItem: (FileItem) -> SyncPairStatusDisplay
    let syncPairExistsForItem: (FileItem) -> Bool
    let syncPairStatusVersion: Int
    let canSetFileType: Bool
    let canGetInfoForItem: (FileItem) -> Bool
    let canDownloadForItem: (FileItem) -> Bool
    let canDeleteForItem: (FileItem) -> Bool
    let canUploadToDirectory: (FileItem) -> Bool
    let canCreateFolderInDirectory: (FileItem) -> Bool
    let onUploadURLs: ([URL], FileItem) -> Void
    let onMoveRemoteItem: (_ sourcePath: String, _ destinationDirectory: FileItem) async throws -> Void

    @State private var columnWidths: [UUID: CGFloat] = [:]
    @State private var multiSelectionPathsByColumn: [UUID: Set<String>] = [:]
    @State private var previewWidth: CGFloat = 320

    private var platformBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(.secondarySystemBackground)
        #endif
    }

    var body: some View {
        ScrollView(.horizontal) {
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    ForEach(Array(filesViewModel.columns.enumerated()), id: \.element.id) { index, column in
                        columnView(column, at: index, proxy: proxy)
                        ColumnResizeHandle(width: binding(for: column.id))
                    }

                    FilePreviewColumn(selectedItem: filesViewModel.selectedItem)
                        .frame(width: previewWidth)

                    ColumnResizeHandle(width: $previewWidth)
                }
                .onAppear {
                    previewWidth = min(max(previewWidth, 240), 620)
                }
                .onChange(of: filesViewModel.columns.count) { _, _ in
                    syncColumnSelections()
                    notifySelectionItemsChanged()
                    guard let last = filesViewModel.columns.last else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.smooth) {
                            proxy.scrollTo(last.id, anchor: .trailing)
                        }
                    }
                }
            }
        }
        .background(colorScheme == .light ? Color.white : platformBackgroundColor)
        .onAppear {
            notifySelectionItemsChanged()
        }
    }

    private func columnView(_ column: FileColumn, at index: Int, proxy: ScrollViewProxy) -> some View {
        let onAppend: (FileColumn) -> Void = { appended in
            proxy.scrollTo(appended.id, anchor: .trailing)
        }
#if os(macOS)
        return AppKitFileColumnTableView(
            bookmarkID: connectionID,
            transferManager: transfers,
            onDownloadTransferError: { item, message in
                filesViewModel.error = WiredError(
                    withTitle: "Download Error",
                    message: "Impossible de télécharger \"\(item.name)\":\n\(message)"
                )
            },
            column: column,
            selectedPaths: selectionPaths(for: column),
            onSelectionChange: { paths, primaryPath in
                multiSelectionPathsByColumn[column.id] = paths
                onPrimarySelectionChange(primaryPath)
                notifySelectionItemsChanged()
                guard let primaryPath,
                      let primaryItem = column.items.first(where: { $0.path == primaryPath }) else { return }

                if paths.count == 1 {
                    filesViewModel.selectColumnItem(
                        id: primaryItem.id,
                        at: index,
                        onColumnAppended: onAppend
                    )
                }
            },
            onDownloadSingleFile: { item in
                guard canDownloadForItem(item) else { return }
                onRequestDownloadSelection([item])
            },
            onUploadURLs: onUploadURLs,
            onMoveRemoteItem: onMoveRemoteItem,
            onRequestCreateFolder: onRequestCreateFolder,
            onRequestUploadInDirectory: onRequestUploadInDirectory,
            onRequestDeleteSelection: onRequestDeleteSelection,
            onRequestDownloadSelection: onRequestDownloadSelection,
            onRequestGetInfo: onRequestGetInfo,
            onRequestSyncNow: onRequestSyncNow,
            onRequestActivateSync: onRequestActivateSync,
            onRequestDeactivateSync: onRequestDeactivateSync,
            syncPairStatusForItem: syncPairStatusForItem,
            syncPairExistsForItem: syncPairExistsForItem,
            syncPairStatusVersion: syncPairStatusVersion,
            canSetFileType: canSetFileType,
            canGetInfoForItem: canGetInfoForItem,
            canDownloadForItem: canDownloadForItem,
            canDeleteForItem: canDeleteForItem,
            canUploadToDirectory: canUploadToDirectory,
            canCreateFolderInDirectory: canCreateFolderInDirectory,
            savedScrollOffset: filesViewModel.columnScrollOffsets[column.id] ?? 0,
            onScrollOffsetChange: { filesViewModel.columnScrollOffsets[column.id] = $0 }
        )
        .frame(width: width(for: column))
        .background(Color.clear)
        .id(column.id)
#else
        return List(column.items, id: \.path) { item in
            Button {
                let paths: Set<String> = [item.path]
                multiSelectionPathsByColumn[column.id] = paths
                onPrimarySelectionChange(item.path)
                notifySelectionItemsChanged()

                if item.type.isDirectoryLike {
                    filesViewModel.selectColumnItem(
                        id: item.id,
                        at: index,
                        onColumnAppended: onAppend
                    )
                }
            } label: {
                HStack(spacing: 8) {
                    FinderFileIconView(item: item, size: 16)
                    Text(item.name)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .frame(width: width(for: column))
        .background(Color.clear)
        .id(column.id)
#endif
    }

    private func width(for column: FileColumn) -> CGFloat {
        min(max(columnWidths[column.id] ?? 240, 180), 620)
    }

    private func binding(for id: UUID) -> Binding<CGFloat> {
        Binding(
            get: { min(max(columnWidths[id] ?? 240, 180), 620) },
            set: { columnWidths[id] = min(max($0, 180), 620) }
        )
    }

    private func syncColumnSelections() {
        var next: [UUID: Set<String>] = [:]
        for column in filesViewModel.columns {
            let existing = multiSelectionPathsByColumn[column.id] ?? []
            let validPaths = Set(column.items.map(\.path))
            let kept = existing.intersection(validPaths)
            if !kept.isEmpty {
                next[column.id] = kept
            } else if let selection = column.selection,
                      let selected = column.items.first(where: { $0.id == selection }) {
                next[column.id] = [selected.path]
            }
        }
        multiSelectionPathsByColumn = next
    }

    private func notifySelectionItemsChanged() {
        var selected: [FileItem] = []
        for column in filesViewModel.columns {
            let selectedPaths = selectionPaths(for: column)
            for item in column.items where selectedPaths.contains(item.path) {
                selected.append(item)
            }
        }
        var seen: Set<String> = []
        let unique = selected.filter { seen.insert($0.path).inserted }
        onSelectionItemsChange(unique)
    }

    private func selectionPaths(for column: FileColumn) -> Set<String> {
        if let stored = multiSelectionPathsByColumn[column.id], !stored.isEmpty {
            return stored
        }
        guard let selection = column.selection,
              let selected = column.items.first(where: { $0.id == selection }) else {
            return []
        }
        return [selected.path]
    }
}

#if os(macOS)
private var wiredRemotePathPasteboardType = NSPasteboard.PasteboardType("com.read-write.wired.remote-path")

private struct AppKitFileColumnTableView: NSViewRepresentable {
    let bookmarkID: UUID
    let transferManager: TransferManager
    let onDownloadTransferError: (FileItem, String) -> Void
    let column: FileColumn
    let selectedPaths: Set<String>
    let onSelectionChange: (Set<String>, String?) -> Void
    let onDownloadSingleFile: (FileItem) -> Void
    let onUploadURLs: ([URL], FileItem) -> Void
    let onMoveRemoteItem: (_ sourcePath: String, _ destinationDirectory: FileItem) async throws -> Void
    let onRequestCreateFolder: (FileItem) -> Void
    let onRequestUploadInDirectory: (FileItem) -> Void
    let onRequestDeleteSelection: ([FileItem]) -> Void
    let onRequestDownloadSelection: ([FileItem]) -> Void
    let onRequestGetInfo: (FileItem) -> Void
    let onRequestSyncNow: (FileItem) -> Void
    let onRequestActivateSync: (FileItem) -> Void
    let onRequestDeactivateSync: (FileItem) -> Void
    let syncPairStatusForItem: (FileItem) -> SyncPairStatusDisplay
    let syncPairExistsForItem: (FileItem) -> Bool
    let syncPairStatusVersion: Int
    let canSetFileType: Bool
    let canGetInfoForItem: (FileItem) -> Bool
    let canDownloadForItem: (FileItem) -> Bool
    let canDeleteForItem: (FileItem) -> Bool
    let canUploadToDirectory: (FileItem) -> Bool
    let canCreateFolderInDirectory: (FileItem) -> Bool
    let savedScrollOffset: CGFloat
    let onScrollOffsetChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 26
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.registerForDraggedTypes([.fileURL, wiredRemotePathPasteboardType])
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.didDoubleClick(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ColumnName"))
        column.title = "Name"
        column.minWidth = 220
        column.width = 300
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.delegate = context.coordinator
        tableView.dataSource = context.coordinator
        let menu = context.coordinator.makeContextMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scrollView
        context.coordinator.syncFromModel(items: self.column.items, selectedPaths: selectedPaths, syncPairStatusVersion: syncPairStatusVersion)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleScrollChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        let offsetToRestore = CGPoint(x: 0, y: savedScrollOffset)
        DispatchQueue.main.async {
            scrollView.contentView.scroll(to: offsetToRestore)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncFromModel(items: self.column.items, selectedPaths: selectedPaths, syncPairStatusVersion: syncPairStatusVersion)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: AppKitFileColumnTableView
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        private var items: [FileItem] = []
        private var byPath: [String: Int] = [:]
        private var lastItemPaths: [String] = []
        private var lastSyncPairStatusVersion: Int = -1
        private var isApplyingSelectionFromSwiftUI = false
        private var contextDirectoryTarget: FileItem

        init(parent: AppKitFileColumnTableView) {
            self.parent = parent
            self.contextDirectoryTarget = FileItem((parent.column.path as NSString).lastPathComponent, path: parent.column.path, type: .directory)
        }

        @objc func handleScrollChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            parent.onScrollOffsetChange(sv.contentView.bounds.origin.y)
        }

        private func isDirectory(_ item: FileItem) -> Bool {
            item.type.isDirectoryLike
        }

        private func columnDirectory() -> FileItem {
            FileItem((parent.column.path as NSString).lastPathComponent, path: parent.column.path, type: .directory)
        }

        private func desiredColumnWidth(for items: [FileItem]) -> CGFloat {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let longestTextWidth = items.reduce(CGFloat(0)) { partial, item in
                let width = (item.name as NSString).size(withAttributes: [.font: font]).width
                return max(partial, width)
            }
            let paddedWidth = longestTextWidth + 64 + 24
            return min(max(220, ceil(paddedWidth)), 420)
        }

        func syncFromModel(items: [FileItem], selectedPaths: Set<String>, syncPairStatusVersion: Int) {
            let newPaths = items.map(\.path)
            let listChanged = newPaths != lastItemPaths
            let syncStatusChanged = syncPairStatusVersion != lastSyncPairStatusVersion
            lastItemPaths = newPaths
            lastSyncPairStatusVersion = syncPairStatusVersion
            self.items = items
            var map: [String: Int] = [:]
            for (idx, item) in items.enumerated() {
                map[item.path] = idx
            }
            self.byPath = map
            contextDirectoryTarget = columnDirectory()
            if let tableColumn = tableView?.tableColumns.first {
                tableColumn.width = desiredColumnWidth(for: items)
            }
            if listChanged {
                // Item list changed: full reload needed.
                tableView?.reloadData()
            } else if syncStatusChanged {
                // Only sync-pair status may have changed: targeted reload of .sync rows only.
                // This avoids resetting the selection for unrelated state updates.
                let syncRows = IndexSet(items.indices.filter { items[$0].type == .sync })
                if !syncRows.isEmpty {
                    tableView?.reloadData(forRowIndexes: syncRows, columnIndexes: IndexSet(integer: 0))
                }
            }
            updateSelection(selectedPaths)
        }

        private func updateSelection(_ selectedPaths: Set<String>) {
            guard let tableView else { return }
            var indexSet = IndexSet()
            for path in selectedPaths {
                if let row = byPath[path] {
                    indexSet.insert(row)
                }
            }

            if tableView.selectedRowIndexes != indexSet {
                isApplyingSelectionFromSwiftUI = true
                tableView.selectRowIndexes(indexSet, byExtendingSelection: false)
                isApplyingSelectionFromSwiftUI = false
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0 && row < items.count else { return nil }
            let item = items[row]
            let id = NSUserInterfaceItemIdentifier("ColumnCell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.imageScaling = .scaleProportionallyUpOrDown
                cell.imageView = icon

                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(tf)
                cell.textField = tf
                cell.addSubview(icon)

                let statusIcon = NSImageView()
                statusIcon.identifier = NSUserInterfaceItemIdentifier("SyncStatusIcon")
                statusIcon.translatesAutoresizingMaskIntoConstraints = false
                statusIcon.imageScaling = .scaleProportionallyUpOrDown
                cell.addSubview(statusIcon)

                let statusSpinner = NSProgressIndicator()
                statusSpinner.identifier = NSUserInterfaceItemIdentifier("SyncStatusSpinner")
                statusSpinner.translatesAutoresizingMaskIntoConstraints = false
                statusSpinner.controlSize = .regular
                statusSpinner.style = .spinning
                statusSpinner.isDisplayedWhenStopped = false
                cell.addSubview(statusSpinner)

                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: statusIcon.leadingAnchor, constant: -6),
                    tf.trailingAnchor.constraint(lessThanOrEqualTo: statusSpinner.leadingAnchor, constant: -6),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusIcon.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    statusIcon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusIcon.widthAnchor.constraint(equalToConstant: 16),
                    statusIcon.heightAnchor.constraint(equalToConstant: 16),
                    statusSpinner.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                    statusSpinner.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    statusSpinner.widthAnchor.constraint(equalToConstant: 16),
                    statusSpinner.heightAnchor.constraint(equalToConstant: 16)
                ])
                return cell
            }()

            cell.textField?.stringValue = item.name
            cell.imageView?.image = remoteItemIconImage(for: item, size: 16)
            let statusIcon = cell.subviews.compactMap { $0 as? NSImageView }
                .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("SyncStatusIcon") })
            let statusSpinner = cell.subviews.compactMap { $0 as? NSProgressIndicator }
                .first(where: { $0.identifier == NSUserInterfaceItemIdentifier("SyncStatusSpinner") })
            switch parent.syncPairStatusForItem(item) {
            case .hidden:
                statusIcon?.isHidden = true
                statusSpinner?.stopAnimation(nil)
            case .checking:
                statusIcon?.isHidden = true
                statusSpinner?.isHidden = false
                statusSpinner?.startAnimation(nil)
            case .active:
                statusSpinner?.stopAnimation(nil)
                statusIcon?.isHidden = false
                statusIcon?.contentTintColor = .systemGreen
                statusIcon?.image = NSImage(systemSymbolName: "link.circle.fill", accessibilityDescription: "Pair active")
            case .inactive:
                statusSpinner?.stopAnimation(nil)
                statusIcon?.isHidden = false
                statusIcon?.contentTintColor = .secondaryLabelColor
                statusIcon?.image = NSImage(systemSymbolName: "link.circle", accessibilityDescription: "Pair inactive")
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            if isApplyingSelectionFromSwiftUI { return }
            guard let tableView else { return }

            let selectedRows = tableView.selectedRowIndexes
            var paths = Set<String>()
            for row in selectedRows where row >= 0 && row < items.count {
                paths.insert(items[row].path)
            }

            let primary: String? = {
                if tableView.clickedRow >= 0 && tableView.clickedRow < items.count && selectedRows.contains(tableView.clickedRow) {
                    return items[tableView.clickedRow].path
                }
                if let first = selectedRows.first, first >= 0 && first < items.count {
                    return items[first].path
                }
                return nil
            }()

            parent.onSelectionChange(paths, primary)
        }

        @objc
        func didDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
            guard row >= 0 && row < items.count else { return }
            let item = items[row]
            if !isDirectory(item), parent.canDownloadForItem(item) {
                parent.onDownloadSingleFile(item)
            }
        }

        func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
            let selectedRows = rowIndexes.compactMap { ($0 >= 0 && $0 < items.count) ? $0 : nil }
            guard !selectedRows.isEmpty else { return false }

            let remotePaths = selectedRows.map { items[$0].path }
            let pbItem = NSPasteboardItem()
            pbItem.setString(remotePaths.joined(separator: "\n"), forType: wiredRemotePathPasteboardType)
            pboard.clearContents()
            pboard.writeObjects([pbItem])
            return true
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard row >= 0 && row < items.count else { return nil }
            let item = items[row]
            let isDir = isDirectory(item)
            let fileType: String
            if isDir {
                fileType = UTType.folder.identifier
            } else {
                let ext = (dragExportFileName(for: item) as NSString).pathExtension
                fileType = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
            }

            let delegate = DragPlaceholderPromiseDelegate(item: item)
            delegate.connectionID = parent.bookmarkID
            delegate.transferManager = parent.transferManager
            delegate.onDownloadTransferError = parent.onDownloadTransferError
            let provider = NSFilePromiseProvider(fileType: fileType, delegate: delegate)
            objc_setAssociatedObject(
                provider,
                &dragPromiseDelegateAssociationKey,
                delegate,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            return provider
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : .copy
        }

        private func finderDroppedURLs(from info: NSDraggingInfo) -> [URL] {
            let classes: [AnyClass] = [NSURL.self]
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            return info.draggingPasteboard.readObjects(forClasses: classes, options: options) as? [URL] ?? []
        }

        private func remoteDroppedPaths(from info: NSDraggingInfo) -> [String] {
            let raw = info.draggingPasteboard.string(forType: wiredRemotePathPasteboardType) ?? ""
            return raw
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
        }

        private func destinationForDrop(proposedRow row: Int) -> FileItem? {
            if row >= 0, row < items.count {
                let item = items[row]
                if isDirectory(item) {
                    return item
                }
            }
            return columnDirectory()
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let destination = destinationForDrop(proposedRow: row) else { return [] }

            if !finderDroppedURLs(from: info).isEmpty {
                if row >= 0 {
                    tableView.setDropRow(row, dropOperation: .on)
                } else {
                    tableView.setDropRow(-1, dropOperation: .above)
                }
                return .copy
            }

            let remotePaths = remoteDroppedPaths(from: info)
            guard !remotePaths.isEmpty else { return [] }
            if remotePaths.contains(where: { $0 == destination.path || destination.path.hasPrefix($0 + "/") }) {
                return []
            }
            if row >= 0 {
                tableView.setDropRow(row, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .above)
            }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let destination = destinationForDrop(proposedRow: row) else { return false }

            let urls = finderDroppedURLs(from: info)
            if !urls.isEmpty {
                DispatchQueue.main.async {
                    self.parent.onUploadURLs(urls, destination)
                }
                return true
            }

            let remotePaths = remoteDroppedPaths(from: info)
            guard !remotePaths.isEmpty else { return false }
            for source in remotePaths {
                Task {
                    do {
                        try await parent.onMoveRemoteItem(source, destination)
                    } catch { }
                }
            }
            return true
        }

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.addItem(withTitle: "Download", action: #selector(contextDownload), keyEquivalent: "")
            menu.addItem(withTitle: "Delete", action: #selector(contextDelete), keyEquivalent: "")
            menu.addItem(withTitle: "Upload…", action: #selector(contextUpload), keyEquivalent: "")
            menu.addItem(withTitle: "Get Info", action: #selector(contextGetInfo), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            let statusItem = menu.addItem(withTitle: "Sync Status: Pair inactive", action: nil, keyEquivalent: "")
            statusItem.tag = SyncContextMenuItemTag.status
            let toggleItem = menu.addItem(withTitle: "Activate Sync Pair", action: #selector(contextToggleSyncPair), keyEquivalent: "")
            toggleItem.tag = SyncContextMenuItemTag.toggle
            let syncNowItem = menu.addItem(withTitle: "Sync Now", action: #selector(contextSyncNow), keyEquivalent: "")
            syncNowItem.tag = SyncContextMenuItemTag.syncNow
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "New Folder", action: #selector(contextNewFolder), keyEquivalent: "")
            for item in menu.items {
                item.target = self
            }
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let tableView else { return }
            let row = tableView.clickedRow

            if row >= 0 && row < items.count {
                if !tableView.selectedRowIndexes.contains(row) {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }

                let item = items[row]
                if isDirectory(item) {
                    contextDirectoryTarget = item
                } else {
                    contextDirectoryTarget = columnDirectory()
                }
            } else {
                if !tableView.selectedRowIndexes.isEmpty {
                    tableView.deselectAll(nil)
                }
                contextDirectoryTarget = columnDirectory()
            }

            let selected = selectedItems()
            menu.item(withTitle: "Download")?.isEnabled = selected.contains(where: { parent.canDownloadForItem($0) })
            menu.item(withTitle: "Delete")?.isEnabled = selected.contains(where: { parent.canDeleteForItem($0) })
            menu.item(withTitle: "Upload…")?.isEnabled = parent.canUploadToDirectory(contextDirectoryTarget)
            let canGetSelectedInfo: Bool = {
                guard selected.count == 1, let item = selected.first else { return false }
                return parent.canGetInfoForItem(item)
            }()
            menu.item(withTitle: "Get Info")?.isEnabled = canGetSelectedInfo
            let selectedSyncItem: FileItem? = {
                guard selected.count == 1, let item = selected.first, item.type == .sync else { return nil }
                return item
            }()
            let syncState: SyncPairStatusDisplay = selectedSyncItem.map { parent.syncPairStatusForItem($0) } ?? .hidden
            let pairExists = selectedSyncItem.map { parent.syncPairExistsForItem($0) } ?? false
            if let syncStatusItem = menu.item(withTag: SyncContextMenuItemTag.status) {
                switch syncState {
                case .active:
                    syncStatusItem.title = "Sync Status: Pair active"
                case .inactive:
                    syncStatusItem.title = "Sync Status: Pair inactive"
                case .checking:
                    syncStatusItem.title = "Sync Status: Updating…"
                case .hidden:
                    syncStatusItem.title = "Sync Status: Pair inactive"
                }
                syncStatusItem.isHidden = selectedSyncItem == nil
                syncStatusItem.isEnabled = false
            }
            if let toggleItem = menu.item(withTag: SyncContextMenuItemTag.toggle) {
                if selectedSyncItem == nil {
                    toggleItem.title = "Activate Sync Pair"
                    toggleItem.isEnabled = false
                } else if syncState == .checking {
                    toggleItem.title = pairExists ? "Deactivate Sync Pair" : "Activate Sync Pair"
                    toggleItem.isEnabled = false
                } else if pairExists {
                    toggleItem.title = "Deactivate Sync Pair"
                    toggleItem.isEnabled = true
                } else {
                    toggleItem.title = "Activate Sync Pair"
                    toggleItem.isEnabled = true
                }
                toggleItem.isHidden = selectedSyncItem == nil
            }
            menu.item(withTag: SyncContextMenuItemTag.syncNow)?.isHidden = selectedSyncItem == nil
            menu.item(withTag: SyncContextMenuItemTag.syncNow)?.isEnabled = selectedSyncItem != nil && pairExists && syncState != .checking
            menu.item(withTitle: "New Folder")?.isEnabled = parent.canCreateFolderInDirectory(contextDirectoryTarget)
        }

        private func selectedItems() -> [FileItem] {
            guard let tableView else { return [] }
            return tableView.selectedRowIndexes.compactMap { row in
                guard row >= 0 && row < items.count else { return nil }
                return items[row]
            }
        }

        @objc private func contextDownload() {
            let selected = selectedItems().filter { parent.canDownloadForItem($0) }
            guard !selected.isEmpty else { return }
            parent.onRequestDownloadSelection(selected)
        }

        @objc private func contextDelete() {
            let selected = selectedItems().filter { parent.canDeleteForItem($0) }
            guard !selected.isEmpty else { return }
            parent.onRequestDeleteSelection(selected)
        }

        @objc private func contextUpload() {
            guard parent.canUploadToDirectory(contextDirectoryTarget) else { return }
            parent.onRequestUploadInDirectory(contextDirectoryTarget)
        }

        @objc private func contextGetInfo() {
            guard let item = selectedItems().first else { return }
            guard parent.canGetInfoForItem(item) else { return }
            parent.onRequestGetInfo(item)
        }

        @objc private func contextSyncNow() {
            guard let item = selectedItems().first, item.type == .sync else { return }
            parent.onRequestSyncNow(item)
        }

        @objc private func contextToggleSyncPair() {
            guard let item = selectedItems().first, item.type == .sync else { return }
            if parent.syncPairStatusForItem(item) == .checking {
                return
            }
            if parent.syncPairExistsForItem(item) {
                parent.onRequestDeactivateSync(item)
            } else {
                parent.onRequestActivateSync(item)
            }
        }

        @objc private func contextNewFolder() {
            guard parent.canCreateFolderInDirectory(contextDirectoryTarget) else { return }
            parent.onRequestCreateFolder(contextDirectoryTarget)
        }
    }
}
#endif

private struct ColumnResizeHandle: View {
    @Binding var width: CGFloat
    @State private var dragStartWidth: CGFloat = 0
    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(isDragging ? 0.55 : (isHovering ? 0.38 : 0.18)))
            .frame(width: 1)
        .contentShape(Rectangle())
#if os(macOS)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
#endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                        }
                        if dragStartWidth == 0 {
                            dragStartWidth = width
                        }
                        width = min(max(dragStartWidth + value.translation.width, 180), 620)
                    }
                    .onEnded { _ in
                        dragStartWidth = 0
                        isDragging = false
                    }
            )
    }
}

private struct FilePreviewColumn: View {
    let selectedItem: FileItem?
    @Environment(\.colorScheme) private var colorScheme

    private var platformBackgroundColor: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(.secondarySystemBackground)
        #endif
    }

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item = selectedItem {
                HStack {
                    Spacer()
                    VStack(alignment: .center, spacing: 10) {
                        FinderFileIconView(item: item, size: 128)
                        
                        Text(item.name.isEmpty ? item.path : item.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                Divider()

                Group {
                    infoRow("Type", item.type.description)
                    infoRow("Size", sizeString(for: item))
                    infoRow("Created", dateString(item.creationDate))
                    infoRow("Modified", dateString(item.modificationDate))
                    infoRow("Contains", containsString(for: item))
                }
            } else {
                Text("Select a file or folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(colorScheme == .light ? Color.white : platformBackgroundColor)
    }

    @ViewBuilder
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(1)
            Spacer()
        }
    }

    private func containsString(for item: FileItem) -> String {
        if item.type.isDirectoryLike {
            return "\(item.directoryCount)"
        }
        return "-"
    }

    private func dateString(_ date: Date?) -> String {
        guard let date else { return "-" }
        return dateFormatter.string(from: date)
    }
}


extension View {
    public func sizeString(for item: FileItem) -> String {
        if item.type.isDirectoryLike {
            return "-"
        }
        let total = Int64(item.dataSize + item.rsrcSize)
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}

private struct FinderFileIconView: View {
    let item: FileItem
    let size: CGFloat

    var body: some View {
        #if os(macOS)
        Image(nsImage: iconImage())
            .resizable()
            .frame(width: size, height: size)
        #else
        Image(systemName: item.type == .file ? "document" : "folder")
            .font(.system(size: size * 0.7))
        #endif
    }

    #if os(macOS)
    private func iconImage() -> NSImage {
        remoteItemIconImage(for: item, size: size)
    }
    #endif
}
