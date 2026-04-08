import Foundation
import Darwin

@main
struct WiredSyncDaemonMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            try runServer()
        } catch {
            fputs("wiredsyncd: (error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
