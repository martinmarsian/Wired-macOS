import Foundation

enum RemoteQuickLookSupport {
    static let maxPreviewSizeBytes: UInt64 = 10 * 1_024 * 1_024
    static let confirmationThresholdBytes: UInt64 = 512 * 1_024

    static func isPreviewable(_ item: FileItem) -> Bool {
        item.type == .file && item.dataSize <= maxPreviewSizeBytes
    }

    static func shouldConfirmDownload(for item: FileItem, hasCachedPreview: Bool) -> Bool {
        !hasCachedPreview && item.dataSize >= confirmationThresholdBytes
    }

    static func selectedPreviewableItems(
        from orderedItems: [FileItem],
        selectedPaths: Set<String>
    ) -> [FileItem] {
        orderedItems.filter { selectedPaths.contains($0.path) && isPreviewable($0) }
    }

    static func initialSelectionIndex(
        items: [FileItem],
        preferredPath: String?
    ) -> Int {
        guard let preferredPath,
              let index = items.firstIndex(where: { $0.path == preferredPath }) else {
            return 0
        }

        return index
    }

    static func cacheDirectory(baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent("RemoteQuickLook", isDirectory: true)
    }

    static func previewURL(
        baseDirectory: URL,
        connectionID: UUID,
        item: FileItem
    ) -> URL {
        let ext = (item.name as NSString).pathExtension
        let baseName = ext.isEmpty ? item.name : (item.name as NSString).deletingPathExtension
        let sanitizedName = sanitizedFileComponent(baseName)
        let pathHash = normalizedHash("\(connectionID.uuidString.lowercased()):\(item.path)")
        let fileName: String
        if ext.isEmpty {
            fileName = "\(sanitizedName)-\(pathHash)"
        } else {
            fileName = "\(sanitizedName)-\(pathHash).\(ext)"
        }
        return cacheDirectory(baseDirectory: baseDirectory).appendingPathComponent(fileName, isDirectory: false)
    }

    private static func sanitizedFileComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let pieces = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        let joined = pieces.joined(separator: "-")
        return joined.isEmpty ? "Preview" : joined
    }

    private static func normalizedHash(_ value: String) -> String {
        let data = Data(value.utf8)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
