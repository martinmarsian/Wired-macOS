import XCTest
@testable import wiredsyncd

final class wiredsyncdTests: XCTestCase {
    func testSyncModeRawValues() {
        XCTAssertEqual(SyncMode.serverToClient.rawValue, "server_to_client")
        XCTAssertEqual(SyncMode.clientToServer.rawValue, "client_to_server")
        XCTAssertEqual(SyncMode.bidirectional.rawValue, "bidirectional")
    }
}
