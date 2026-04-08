#if os(macOS)
import AppKit

enum SyncContextMenuItemTag {
    static let status = 9_101
    static let toggle = 9_102
    static let syncNow = 9_103
}

var wiredRemotePathPasteboardType = NSPasteboard.PasteboardType("com.read-write.wired.remote-path")
#endif
