import XCTest
import Foundation
import SQLite3
@testable import wiredsyncd

final class wiredsyncdTests: XCTestCase {
    func testPathLayoutSupportsEnvironmentOverrides() {
        let layout = PathLayout(environment: [
            PathLayout.appSupportDirEnv: "/tmp/wiredsyncd-tests/app-support",
            PathLayout.runDirEnv: "/tmp/wiredsyncd-tests/run"
        ])

        XCTAssertEqual(layout.baseDir.path, "/tmp/wiredsyncd-tests/app-support")
        XCTAssertEqual(layout.configPath.path, "/tmp/wiredsyncd-tests/app-support/config.json")
        XCTAssertEqual(layout.statePath.path, "/tmp/wiredsyncd-tests/app-support/state.sqlite")
        XCTAssertEqual(layout.runDir.path, "/tmp/wiredsyncd-tests/run")
        XCTAssertEqual(layout.socketPath.path, "/tmp/wiredsyncd-tests/run/wiredsyncd.sock")
    }

    func testSyncModeRawValues() {
        XCTAssertEqual(SyncMode.serverToClient.rawValue, "server_to_client")
        XCTAssertEqual(SyncMode.clientToServer.rawValue, "client_to_server")
        XCTAssertEqual(SyncMode.bidirectional.rawValue, "bidirectional")
    }

    func testShouldIgnoreSyncRelativePathFiltersTemporaryAndHiddenArtifacts() {
        XCTAssertTrue(shouldIgnoreSyncRelativePath(".DS_Store", excludePatterns: []))
        XCTAssertTrue(shouldIgnoreSyncRelativePath("folder/.secret/file.txt", excludePatterns: []))
        XCTAssertTrue(shouldIgnoreSyncRelativePath("movie.mp4.WiredTransfer", excludePatterns: []))
        XCTAssertTrue(shouldIgnoreSyncRelativePath("movie 2.WiredTransfer", excludePatterns: []))
        XCTAssertTrue(shouldIgnoreSyncRelativePath("archive.zip.wiredsync.part", excludePatterns: []))
        XCTAssertTrue(shouldIgnoreSyncRelativePath("report.conflict.user.1234.txt", excludePatterns: []))
        XCTAssertTrue(shouldIgnoreSyncRelativePath("cache/tmp.bin", excludePatterns: ["cache/*"]))
        XCTAssertFalse(shouldIgnoreSyncRelativePath("notes/final.txt", excludePatterns: []))
    }

    func testSyncEndpointEncodingOmitsPassword() throws {
        let endpoint = SyncEndpoint(serverURL: "wired.example.org", login: "alice", password: "secret")
        let data = try JSONEncoder().encode(endpoint)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains("serverURL"))
        XCTAssertTrue(json.contains("login"))
        XCTAssertFalse(json.contains("password"))
        XCTAssertFalse(json.contains("secret"))
    }

    func testSyncEndpointDecodingSupportsLegacyPasswordPayload() throws {
        let legacyJSON = #"{"server_url":"wired.example.org","login":"alice","password":"secret"}"#
        let endpoint = try JSONDecoder().decode(SyncEndpoint.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(endpoint.serverURL, "wired.example.org")
        XCTAssertEqual(endpoint.login, "alice")
        XCTAssertEqual(endpoint.password, "secret")
    }

    func testSyncPathHelpersClassifyExpectedArtifacts() {
        XCTAssertTrue(syncPathContainsHiddenPathComponent(".hidden/file.txt"))
        XCTAssertTrue(syncPathContainsHiddenPathComponent("visible/.gitkeep"))
        XCTAssertFalse(syncPathContainsHiddenPathComponent("visible/file.txt"))

        XCTAssertTrue(syncPathIsConflictArtifact("notes/report.conflict.alice.1234.txt"))
        XCTAssertFalse(syncPathIsConflictArtifact("notes/report.txt"))

        XCTAssertTrue(syncPathIsTransientTransferArtifact("movie.WiredTransfer"))
        XCTAssertTrue(syncPathIsTransientTransferArtifact("folder/archive.wiredsync.part"))
        XCTAssertFalse(syncPathIsTransientTransferArtifact("folder/archive.zip"))
    }

    func testSyncPathIsExcludedSupportsFilenamePatternsAndNestedPaths() {
        let cases: [(path: String, patterns: [String], expected: Bool)] = [
            ("Thumbs.db", ["Thumbs.db"], true),
            ("folder/Thumbs.db", ["Thumbs.db"], true),
            ("cache/tmp.bin", ["cache/*"], true),
            ("cache/nested/tmp.bin", ["cache/*"], false),
            ("docs/report.txt", ["  ", "# comment", "*.jpg"], false),
            ("images/cover.jpg", ["# comment", "*.jpg"], true),
            ("images/cover.jpg", ["images/*"], true),
            ("images/cover.jpg", ["other/*"], false)
        ]

        for testCase in cases {
            XCTAssertEqual(
                syncPathIsExcluded(testCase.path, excludePatterns: testCase.patterns),
                testCase.expected,
                "Unexpected match result for \(testCase.path) with \(testCase.patterns)"
            )
        }
    }

    func testSQLiteStoreCreatesSchemaAndSupportsIdempotentMigrations() throws {
        let environment = try TestEnvironment()
        _ = try environment.makeStore()
        let store = try environment.makeStore()

        XCTAssertEqual(try environment.integerValue("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sync_pairs';"), 1)
        XCTAssertEqual(try environment.integerValue("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'op_queue';"), 1)
        XCTAssertEqual(try environment.integerValue("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'uploaded_items';"), 1)
        XCTAssertEqual(store.queueDepth(), 0)
    }

    func testSQLiteStoreUpsertRemoveAndQueueDepthReflectPersistedState() throws {
        let environment = try TestEnvironment()
        let store = try environment.makeStore()
        let pair = TestData.makePair(id: "pair-1")

        try store.upsert(pair: pair)
        try store.enqueue(pairID: pair.id, opKind: "rescan", payload: "{}")
        try store.markUploaded(pairID: pair.id, relativePath: "docs/readme.txt", size: 12, modificationTime: 34)

        XCTAssertEqual(try environment.integerValue("SELECT COUNT(*) FROM sync_pairs WHERE id = 'pair-1';"), 1)
        XCTAssertEqual(store.queueDepth(), 1)
        XCTAssertEqual(store.uploadedSnapshot(pairID: pair.id, relativePath: "docs/readme.txt")?.size, 12)

        try store.remove(id: pair.id)

        XCTAssertEqual(try environment.integerValue("SELECT COUNT(*) FROM sync_pairs WHERE id = 'pair-1';"), 0)
        XCTAssertNil(store.uploadedSnapshot(pairID: pair.id, relativePath: "docs/readme.txt"))
    }

    func testSQLiteStoreMarksUpdatesPrunesAndClearsUploadedSnapshots() throws {
        let environment = try TestEnvironment()
        let store = try environment.makeStore()
        let pairID = "pair-uploads"

        try store.markUploaded(pairID: pairID, relativePath: "a.txt", size: 10, modificationTime: 100)
        try store.markUploaded(pairID: pairID, relativePath: "b.txt", size: 20, modificationTime: 200)
        try store.markUploaded(pairID: pairID, relativePath: "a.txt", size: 99, modificationTime: 101)

        let snapshot = try XCTUnwrap(store.uploadedSnapshot(pairID: pairID, relativePath: "a.txt"))
        XCTAssertEqual(snapshot.size, 99)
        XCTAssertEqual(snapshot.modificationTime, 101)

        try store.pruneUploadedSnapshots(pairID: pairID, keeping: ["b.txt"])
        XCTAssertNil(store.uploadedSnapshot(pairID: pairID, relativePath: "a.txt"))
        XCTAssertNotNil(store.uploadedSnapshot(pairID: pairID, relativePath: "b.txt"))

        try store.removeUploadedSnapshot(pairID: pairID, relativePath: "b.txt")
        XCTAssertNil(store.uploadedSnapshot(pairID: pairID, relativePath: "b.txt"))

        try store.markUploaded(pairID: pairID, relativePath: "c.txt", size: 30, modificationTime: 300)
        try store.clearUploadedSnapshots(pairID: pairID)
        XCTAssertNil(store.uploadedSnapshot(pairID: pairID, relativePath: "c.txt"))
    }

    func testDaemonStateInitializesFromEmptyConfig() throws {
        let environment = try TestEnvironment()
        let state = try environment.makeState()

        XCTAssertTrue(state.snapshotPairs().isEmpty)
        XCTAssertTrue(state.runtimeStatusesSnapshot().isEmpty)
        XCTAssertEqual(state.status()["pairs_count"] as? Int, 0)
        XCTAssertEqual(state.status()["queue_depth"] as? Int, 0)
    }

    func testDaemonStateInitializesFromPersistedConfigAndMigratesCredentials() throws {
        let environment = try TestEnvironment()
        let fakeSecrets = FakeSecretStore()
        let legacyJSON = """
        {
          "pairs" : [
            {
              "id" : "pair-migrate",
              "remotePath" : "/Uploads",
              "localPath" : "/tmp/uploads",
              "mode" : "bidirectional",
              "deleteRemoteEnabled" : false,
              "excludePatterns" : [],
              "server_url" : "wired.example.org",
              "login" : "alice",
              "password" : "secret",
              "paused" : false,
              "createdAt" : "2023-11-14T22:13:20Z",
              "updatedAt" : "2023-11-14T22:13:20Z"
            }
          ]
        }
        """
        try environment.writeRawConfig(legacyJSON)

        let state = try environment.makeState(secrets: fakeSecrets)
        let migratedPair = try XCTUnwrap(state.pair(id: "pair-migrate"))
        let persistedConfig = try environment.readConfig()

        XCTAssertEqual(migratedPair.endpoint.password, "")
        XCTAssertEqual(fakeSecrets.reads["pair-migrate"], nil)
        XCTAssertEqual(fakeSecrets.writes["pair-migrate"]?.password, "secret")
        XCTAssertEqual(persistedConfig.pairs.first?.endpoint.password, "")
        XCTAssertEqual(state.runtimeStatus(pairID: "pair-migrate")?.state, .disconnected)
        XCTAssertEqual(try environment.integerValue("SELECT COUNT(*) FROM sync_pairs WHERE id = 'pair-migrate';"), 1)
    }

    func testDaemonStateStatusAndTailReflectRuntimeStateChanges() throws {
        let environment = try TestEnvironment()
        let state = try environment.makeState()

        let connected = try state.addPair(
            remotePath: "/connected",
            localPath: "/tmp/connected",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "one.example.org", login: "alice")
        )
        let reconnecting = try state.addPair(
            remotePath: "/reconnecting",
            localPath: "/tmp/reconnecting",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "two.example.org", login: "bob")
        )
        let paused = try state.addPair(
            remotePath: "/paused",
            localPath: "/tmp/paused",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "three.example.org", login: "carol")
        )

        state.setRuntimeStatus(pairID: connected.id, state: .connected)
        state.setRuntimeStatus(pairID: reconnecting.id, state: .reconnecting)
        _ = try state.setPaused(id: paused.id, paused: true)

        for index in 0..<505 {
            state.appendLog("line-\(index)")
        }

        let status = state.status()
        let tail = state.tail(count: 3)

        XCTAssertEqual(status["pairs_count"] as? Int, 3)
        XCTAssertEqual(status["active_pairs"] as? Int, 2)
        XCTAssertEqual(status["connected_pairs"] as? Int, 1)
        XCTAssertEqual(status["reconnecting_pairs"] as? Int, 1)
        XCTAssertEqual(status["error_pairs"] as? Int, 0)
        XCTAssertEqual(state.tail(count: 999).count, 500)
        XCTAssertEqual(tail.count, 3)
        XCTAssertTrue(tail[0].contains("line-502"))
        XCTAssertTrue(tail[2].contains("line-504"))
    }

    func testDaemonStateAddPairPersistsQueueAndRuntimeState() throws {
        let environment = try TestEnvironment()
        let fakeSecrets = FakeSecretStore()
        let state = try environment.makeState(secrets: fakeSecrets)

        let pair = try state.addPair(
            remotePath: "/Uploads",
            localPath: "/tmp/uploads",
            mode: .serverToClient,
            deleteRemoteEnabled: true,
            excludePatterns: ["cache/*"],
            endpoint: SyncEndpoint(serverURL: "wired.example.org", login: "alice", password: "secret")
        )

        let persistedConfig = try environment.readConfig()
        let persistedPair = try XCTUnwrap(persistedConfig.pairs.first)
        let runtime = try XCTUnwrap(state.runtimeStatus(pairID: pair.id))

        XCTAssertEqual(persistedConfig.pairs.count, 1)
        XCTAssertEqual(persistedPair.remotePath, "/Uploads")
        XCTAssertEqual(persistedPair.endpoint.password, "")
        XCTAssertEqual(fakeSecrets.writes[pair.id]?.password, "secret")
        XCTAssertEqual(try environment.integerValue("SELECT COUNT(*) FROM sync_pairs WHERE id = '\(pair.id)';"), 1)
        XCTAssertEqual(state.store.queueDepth(), 1)
        XCTAssertEqual(runtime.state, .disconnected)
        XCTAssertEqual(runtime.retryCount, 0)
        XCTAssertNil(runtime.lastError)
    }

    func testDaemonStateAddPairDeduplicatesAndResetsUploadedCacheWhenPolicyChanges() throws {
        let environment = try TestEnvironment()
        let fakeSecrets = FakeSecretStore()
        let duplicateA = TestData.makePair(
            id: "pair-dup-a",
            remotePath: "/shared",
            localPath: "/tmp/shared",
            mode: .bidirectional,
            endpoint: TestData.endpoint(serverURL: "wired.example.org", login: "alice")
        )
        let duplicateB = TestData.makePair(
            id: "pair-dup-b",
            remotePath: "/shared",
            localPath: "/tmp/shared",
            mode: .bidirectional,
            endpoint: TestData.endpoint(serverURL: "wired.example.org", login: "alice")
        )
        try environment.writeConfig(DaemonConfig(pairs: [duplicateA, duplicateB]))

        let state = try environment.makeState(secrets: fakeSecrets)
        try state.store.markUploaded(pairID: duplicateA.id, relativePath: "old.txt", size: 1, modificationTime: 1)
        try state.store.markUploaded(pairID: duplicateB.id, relativePath: "stale.txt", size: 1, modificationTime: 1)

        let pair = try state.addPair(
            remotePath: "/shared",
            localPath: "/tmp/shared",
            mode: .clientToServer,
            deleteRemoteEnabled: true,
            excludePatterns: ["cache/*"],
            endpoint: SyncEndpoint(serverURL: "wired.example.org", login: "alice", password: "new-secret")
        )

        let persisted = try environment.readConfig()

        XCTAssertEqual(pair.id, duplicateA.id)
        XCTAssertEqual(persisted.pairs.count, 1)
        XCTAssertEqual(persisted.pairs[0].mode, .clientToServer)
        XCTAssertTrue(persisted.pairs[0].deleteRemoteEnabled)
        XCTAssertEqual(persisted.pairs[0].excludePatterns, ["cache/*"])
        XCTAssertNil(state.store.uploadedSnapshot(pairID: duplicateA.id, relativePath: "old.txt"))
        XCTAssertNil(state.store.uploadedSnapshot(pairID: duplicateB.id, relativePath: "stale.txt"))
        XCTAssertEqual(try environment.integerValue("SELECT COUNT(*) FROM sync_pairs WHERE id = 'pair-dup-b';"), 0)
        XCTAssertNotNil(fakeSecrets.writes[pair.id])
    }

    func testDaemonStateRemovePairDeletesPersistedStateAndReturnsFalseWhenMissing() throws {
        let environment = try TestEnvironment()
        let fakeSecrets = FakeSecretStore()
        let state = try environment.makeState(secrets: fakeSecrets)
        let pair = try state.addPair(
            remotePath: "/Uploads",
            localPath: "/tmp/uploads",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "wired.example.org", login: "alice")
        )
        try state.store.markUploaded(pairID: pair.id, relativePath: "file.txt", size: 1, modificationTime: 1)

        XCTAssertTrue(try state.removePair(id: pair.id))
        XCTAssertFalse(try state.removePair(id: pair.id))
        XCTAssertNil(state.runtimeStatus(pairID: pair.id))
        XCTAssertEqual(try environment.integerValue("SELECT COUNT(*) FROM sync_pairs WHERE id = '\(pair.id)';"), 0)
        XCTAssertNil(state.store.uploadedSnapshot(pairID: pair.id, relativePath: "file.txt"))
        XCTAssertTrue(fakeSecrets.deletedPairIDs.contains(pair.id))
    }

    func testDaemonStateRemovePairsFiltersByRemotePathServerAndLogin() throws {
        let environment = try TestEnvironment()
        let fakeSecrets = FakeSecretStore()
        let state = try environment.makeState(secrets: fakeSecrets)
        let pairA = try state.addPair(
            remotePath: "/common",
            localPath: "/tmp/a",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "one.example.org", login: "alice")
        )
        _ = try state.addPair(
            remotePath: "/common",
            localPath: "/tmp/b",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "two.example.org", login: "alice")
        )
        _ = try state.addPair(
            remotePath: "/common",
            localPath: "/tmp/c",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "one.example.org", login: "bob")
        )

        let removed = try state.removePairs(remotePath: "/common", serverURL: " one.example.org ", login: " alice ")

        XCTAssertEqual(removed, [pairA.id])
        XCTAssertEqual(try environment.readConfig().pairs.count, 2)
        XCTAssertTrue(fakeSecrets.deletedPairIDs.contains(pairA.id))
    }

    func testDaemonStateUpdatePairPolicyReturnsChangedIDsAndResetsSnapshots() throws {
        let environment = try TestEnvironment()
        let state = try environment.makeState(secrets: FakeSecretStore())
        let pair = try state.addPair(
            remotePath: "/policy",
            localPath: "/tmp/policy",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "wired.example.org", login: "alice")
        )
        try state.store.markUploaded(pairID: pair.id, relativePath: "file.txt", size: 1, modificationTime: 1)

        let unchanged = try state.updatePairPolicy(
            remotePath: "/policy",
            serverURL: "wired.example.org",
            login: "alice",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            excludePatterns: []
        )
        let changed = try state.updatePairPolicy(
            remotePath: "/policy",
            serverURL: "wired.example.org",
            login: "alice",
            mode: .serverToClient,
            deleteRemoteEnabled: true,
            excludePatterns: ["cache/*"]
        )

        XCTAssertTrue(unchanged.isEmpty)
        XCTAssertEqual(changed, [pair.id])
        XCTAssertNil(state.store.uploadedSnapshot(pairID: pair.id, relativePath: "file.txt"))
        XCTAssertEqual(state.store.queueDepth(), 2)
        XCTAssertEqual(try environment.readConfig().pairs.first?.mode, .serverToClient)
    }

    func testDaemonStateRenamePairRemotePathUpdatesMatchingPairsOnly() throws {
        let environment = try TestEnvironment()
        let state = try environment.makeState(secrets: FakeSecretStore())
        let pairA = try state.addPair(
            remotePath: "/old",
            localPath: "/tmp/a",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "one.example.org", login: "alice")
        )
        _ = try state.addPair(
            remotePath: "/old",
            localPath: "/tmp/b",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "two.example.org", login: "alice")
        )

        let renamed = try state.renamePairRemotePath(
            oldPath: "/old",
            newPath: "/new",
            serverURL: "one.example.org",
            login: "alice"
        )

        let config = try environment.readConfig()
        XCTAssertEqual(renamed, [pairA.id])
        XCTAssertEqual(config.pairs.first(where: { $0.id == pairA.id })?.remotePath, "/new")
        XCTAssertEqual(config.pairs.first(where: { $0.id != pairA.id })?.remotePath, "/old")
    }

    func testDaemonStateSetPausedUpdatesConfigAndRuntimeState() throws {
        let environment = try TestEnvironment()
        let state = try environment.makeState(secrets: FakeSecretStore())
        let pair = try state.addPair(
            remotePath: "/pause",
            localPath: "/tmp/pause",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "wired.example.org", login: "alice")
        )

        XCTAssertTrue(try state.setPaused(id: pair.id, paused: true))
        XCTAssertEqual(state.runtimeStatus(pairID: pair.id)?.state, .paused)
        XCTAssertTrue(try environment.readConfig().pairs.first?.paused ?? false)

        XCTAssertTrue(try state.setPaused(id: pair.id, paused: false))
        XCTAssertEqual(state.runtimeStatus(pairID: pair.id)?.state, .disconnected)
        XCTAssertFalse(try environment.readConfig().pairs.first?.paused ?? true)

        XCTAssertFalse(try state.setPaused(id: "missing", paused: true))
    }

    func testDaemonStateReloadRehydratesPairsAndPreservesCompatibleRuntimeStatuses() throws {
        let environment = try TestEnvironment()
        let state = try environment.makeState(secrets: FakeSecretStore())
        let pairA = try state.addPair(
            remotePath: "/a",
            localPath: "/tmp/a",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "wired.example.org", login: "alice")
        )
        let pairB = try state.addPair(
            remotePath: "/b",
            localPath: "/tmp/b",
            mode: .bidirectional,
            deleteRemoteEnabled: false,
            endpoint: TestData.endpoint(serverURL: "wired.example.org", login: "bob")
        )
        state.setRuntimeStatus(pairID: pairA.id, state: .connected)
        state.setRuntimeStatus(pairID: pairB.id, state: .paused)

        let replacement = TestData.makePair(
            id: pairB.id,
            remotePath: "/b-renamed",
            localPath: "/tmp/b",
            mode: .bidirectional,
            endpoint: TestData.endpoint(serverURL: "wired.example.org", login: "bob"),
            paused: false
        )
        let pausedNew = TestData.makePair(
            id: "pair-new",
            remotePath: "/c",
            localPath: "/tmp/c",
            mode: .bidirectional,
            endpoint: TestData.endpoint(serverURL: "wired.example.org", login: "carol"),
            paused: true
        )
        try environment.writeConfig(DaemonConfig(pairs: [replacement, pausedNew]))

        try state.reload()

        XCTAssertNil(state.pair(id: pairA.id))
        XCTAssertEqual(state.pair(id: pairB.id)?.remotePath, "/b-renamed")
        XCTAssertEqual(state.runtimeStatus(pairID: pairB.id)?.state, .disconnected)
        XCTAssertEqual(state.runtimeStatus(pairID: pausedNew.id)?.state, .paused)
        XCTAssertEqual(Set(state.runtimeStatusesSnapshot().keys), Set([pairB.id, pausedNew.id]))
    }

    func testDaemonStateShutdownMarksDaemonAsNotRunning() throws {
        let environment = try TestEnvironment()
        let state = try environment.makeState(secrets: FakeSecretStore())

        XCTAssertTrue(state.isRunning())
        state.shutdown()
        XCTAssertFalse(state.isRunning())
    }
}

private enum TestData {
    static let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    static func endpoint(
        serverURL: String = "wired.example.org",
        login: String = "alice",
        password: String = ""
    ) -> SyncEndpoint {
        SyncEndpoint(serverURL: serverURL, login: login, password: password)
    }

    static func makePair(
        id: String = UUID().uuidString,
        remotePath: String = "/Uploads",
        localPath: String = "/tmp/uploads",
        mode: SyncMode = .bidirectional,
        deleteRemoteEnabled: Bool = false,
        excludePatterns: [String] = [],
        endpoint: SyncEndpoint = endpoint(),
        paused: Bool = false,
        createdAt: Date = referenceDate,
        updatedAt: Date = referenceDate
    ) -> SyncPair {
        SyncPair(
            id: id,
            remotePath: remotePath,
            localPath: localPath,
            mode: mode,
            deleteRemoteEnabled: deleteRemoteEnabled,
            excludePatterns: excludePatterns,
            endpoint: endpoint,
            paused: paused,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private final class FakeSecretStore: SecretStore {
    struct Write {
        let password: String
        let endpoint: SyncEndpoint
    }

    private(set) var reads: [String: String] = [:]
    private(set) var writes: [String: Write] = [:]
    private(set) var deletedPairIDs: [String] = []

    func readPassword(pairID: String) throws -> String? {
        reads[pairID]
    }

    func writePassword(_ password: String, pairID: String, endpoint: SyncEndpoint) throws {
        writes[pairID] = Write(password: password, endpoint: endpoint)
    }

    func deletePassword(pairID: String) throws {
        deletedPairIDs.append(pairID)
        writes.removeValue(forKey: pairID)
        reads.removeValue(forKey: pairID)
    }
}

private final class TestEnvironment {
    let rootURL: URL
    let paths: PathLayout

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let environment = [
            PathLayout.appSupportDirEnv: rootURL.appendingPathComponent("app-support", isDirectory: true).path,
            PathLayout.runDirEnv: rootURL.appendingPathComponent("run", isDirectory: true).path
        ]
        paths = PathLayout(environment: environment)
        try paths.ensureDirectories()

        if !FileManager.default.fileExists(atPath: paths.configPath.path) {
            try writeConfig(DaemonConfig())
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func makeStore() throws -> SQLiteStore {
        try SQLiteStore(path: paths.statePath.path)
    }

    func makeState(secrets: SecretStore = FakeSecretStore()) throws -> DaemonState {
        try DaemonState(paths: paths, store: makeStore(), secrets: secrets)
    }

    func writeConfig(_ config: DaemonConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: paths.configPath, options: .atomic)
    }

    func writeRawConfig(_ json: String) throws {
        try Data(json.utf8).write(to: paths.configPath, options: .atomic)
    }

    func readConfig() throws -> DaemonConfig {
        let data = try Data(contentsOf: paths.configPath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DaemonConfig.self, from: data)
    }

    func integerValue(_ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(paths.statePath.path, &db) == SQLITE_OK, let db else {
            XCTFail("Unable to open sqlite database")
            return 0
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            XCTFail("Unable to prepare sql: \(sql)")
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            XCTFail("Expected a row for sql: \(sql)")
            return 0
        }
        return Int(sqlite3_column_int(statement, 0))
    }
}
