import XCTest
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
}
