import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit

private enum RemoteFolderIconKind: String {
    case directory
    case uploads
    case dropbox
    case sync
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

func remoteItemIconImage(for item: FileItem, size: CGFloat) -> NSImage {
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
